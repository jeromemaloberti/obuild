open Printf
open Ext
open Types
open Helper
open Filepath
open Gconf

let major = 0
let minor = 0

let programName = "obuild"
let usageStr cmd = "\nusage: " ^ programName ^ " " ^ cmd ^ " <options>\n\noptions:\n"

let project_read () =
    try Project.read gconf.conf_strict
    with exn -> verbose Verbose "exception during project read: %s\n" (Printexc.to_string exn); raise exn

let mainConfigure argv =
    let userFlagSettings = ref [] in
    let userSetFlagSettings s =
        let tweak =
            if string_startswith "-" s
                then ClearFlag (string_drop 1 s)
                else SetFlag s
            in
        userFlagSettings := tweak :: !userFlagSettings
        in

    let enable_disable_opt opt_name f doc =
        [ ("--enable-" ^ opt_name, Arg.Unit (f true), " enable " ^ doc)
        ; ("--disable-" ^ opt_name, Arg.Unit (f false), "disable " ^ doc)
        ]
        in

    let opts =
        [ ("--flag", Arg.String userSetFlagSettings, "enable or disable a project's flag")
        ; ("--executable-as-obj", Arg.Unit (Configure.set_exe_as_obj true), "output executable as obj file")
        ]
        in
    Arg.parse_argv (Array.of_list argv)
        ( enable_disable_opt "library-bytecode" Configure.set_lib_bytecode "library compilation as bytecode"
        @ enable_disable_opt "library-native" Configure.set_lib_native "library compilation as native"
        @ enable_disable_opt "executable-bytecode" Configure.set_exe_bytecode "executable compilation as bytecode"
        @ enable_disable_opt "executable-native" Configure.set_exe_native "executable compilation as native"
        @ enable_disable_opt "library-profiling" Configure.set_lib_profiling "library profiling"
        @ enable_disable_opt "library-debugging" Configure.set_lib_debugging "library debugging"
        @ enable_disable_opt "executable-profiling" Configure.set_exe_profiling "executable profiling"
        @ enable_disable_opt "executable-debugging" Configure.set_exe_debugging "executable debugging"
        @ enable_disable_opt "examples" Configure.set_build_examples "building examples"
        @ enable_disable_opt "benchs" Configure.set_build_benchs "building benchs"
        @ enable_disable_opt "tests" Configure.set_build_tests "building tests"
        @ opts
        ) (fun s -> failwith ("unknown option: " ^ s))
        (usageStr "configure");

    FindlibConf.load ();
    let projFile = Project.read gconf.conf_strict in
    verbose Report "Configuring %s-%s...\n" projFile.Project.name projFile.Project.version;
    Configure.run projFile !userFlagSettings;
    (* check build deps of everything buildables *)
    ()

let build_options =
    [ ("-j", Arg.Int (fun i -> gconf.conf_parallel_jobs <- i), "maximum number of jobs in parallel")
    ; ("--jobs", Arg.Int (fun i -> gconf.conf_parallel_jobs <- i), "maximum number of jobs in parallel")
    ]

let mainBuild argv =
    Arg.parse_argv (Array.of_list argv) (build_options @
        [ ("--dot", Arg.Unit (fun () -> gconf.conf_dump_dot <- true), "dump dependencies dot files during build")
        ]) (fun s -> failwith ("unknown option: " ^ s))
        (usageStr "build");

    Configure.check ();
    let projFile = project_read () in
    FindlibConf.load ();
    let project = Analyze.prepare projFile in
    let bstate = Prepare.init project in

    let taskdep = Taskdep.init project.Analyze.project_targets_dag in
    while not (Taskdep.isComplete taskdep) do
        (match Taskdep.getnext taskdep with
        | None -> failwith "no free task in targets"
        | Some (step,ntask) ->
            verbose Verbose "building target %s\n%!" (name_to_string ntask);
            (match ntask with
            | ExeName name   -> Build.buildExe bstate (Project.find_exe projFile name)
            | LibName name   -> Build.buildLib bstate (Project.find_lib projFile name)
            | BenchName name -> Build.buildBench bstate (Project.find_bench projFile name)
            | TestName name  -> Build.buildTest bstate (Project.find_test projFile name)
            | ExampleName name -> Build.buildExample bstate (Project.find_example projFile name)
            );
            Taskdep.markDone taskdep ntask
        )
    done;
    ()

let mainClean argv =
    if Filesystem.exists (Dist.getDistPath ())
        then Filesystem.removeDir (Dist.getDistPath ())
        else ()

let mainSdist argv =
    let isSnapshot = ref false in
    Arg.parse_argv (Array.of_list argv)
           [ ("--snapshot", Arg.Set isSnapshot, "build a snapshot of the project")
           ] (fun s -> failwith ("unknown option: " ^ s))
           (usageStr "sdist");
    Dist.check (fun () -> ());

    let projFile = project_read () in
    Sdist.run projFile !isSnapshot;
    ()

let mainDoc argv =
    Arg.parse_argv (Array.of_list argv)
           [
           ] (fun s -> failwith ("unknown option: " ^ s))
           (usageStr "doc");

    let projFile = project_read () in
    Doc.run projFile;
    ()

let mainInstall argv =
    let destdir = ref "" in
    Dist.check (fun () -> ());
    Arg.parse_argv (Array.of_list argv)
           [ ("destdir", Arg.Set_string destdir, "override destination where to install (default coming from findlib configuration)")
           ] (fun s -> failwith ("unknown option: " ^ s))
           (usageStr "install");
    FindlibConf.load ();

    let projFile = project_read () in
    List.iter (fun target ->
        let buildDir = Dist.getBuildDest (Dist.Target target.Target.target_name) in
        let files = Build.get_destination_files target in
        Build.sanity_check buildDir target;
        verbose Report "installing: %s\n" (Utils.showList "," fn_to_string files)
    ) (Project.get_all_buildable_targets projFile);
    ()

let mainTest argv =
    Arg.parse_argv (Array.of_list argv)
           [
           ] (fun s -> failwith ("unknown option: " ^ s))
           (usageStr "test");

    Configure.check ();
    let projFile = project_read () in
    if not gconf.conf_build_tests then (
        eprintf "error: building tests are disabled, re-configure with --enable-tests\n";
        exit 1
    );
    let testTargets = List.map Project.test_to_target projFile.Project.tests in
    if testTargets <> []
        then (
            let results =
                List.map (fun test ->
                    let testTarget = Project.test_to_target test in
                    let outputName = Utils.to_exe_name Normal Native (Target.get_target_dest_name testTarget) in
                    let dir = Dist.getBuildDest (Dist.Target testTarget.Target.target_name) in
                    let exePath = dir </> outputName in
                    if not (Filesystem.exists exePath) then (
                        eprintf "error: %s doesn't appears built, make sure build has been run first\n" (Target.get_target_name testTarget);
                        exit 1
                    );
                    (match Process.run_with_outputs [ fp_to_string exePath ] with
                    | Process.Success _   -> (test.Project.test_name, true)
                    | Process.Failure err ->
                        print_warnings err;
                        (test.Project.test_name, false)
                    )
                ) projFile.Project.tests
                in
            (* this is just a mockup. expect results displayed in javascript and 3d at some point *)
            let failed = List.filter (fun (_,x) -> false = x) results in
            let successes = List.filter (fun (_,x) -> true = x) results in
            let total = List.length failed + List.length successes in
            printf "SUCCESS: %d/%d\n" (List.length successes) total;
            printf "FAILED : %d/%d\n" (List.length failed) total;
            List.iter (fun (n,_) -> printf "  %s\n" n) failed;
            if failed <> [] then exit 1

        ) else
            printf "warning: no tests defined: not doing anything.\n"

let mainInit argv =
    let project = Init.run () in
    let name = fn (project.Project.name) <.> "obuild" in
    Project.write (in_current_dir name) project

let usageCommands = String.concat "\n"
    [ "Commands:"
    ; ""
    ; "  configure    Prepare to build the package."
    ; "  build        Make this package ready for installation."
    ; "  clean        Clean up after a build."
    ; "  sdist        Generate a source distribution file (.tar.gz)."
    ; "  doc          Generate documentation."
    ; "  install      Install this package."
    ; "  test         Run the tests"
    ; "  help         Help about commands"
    ]

let mainHelp argv =
    match argv with
    | []         -> eprintf "usage: obuild help <command>\n\n";
    | command::_ ->
        try
            let msgs = List.assoc command Help.helpMessages in
            List.iter (eprintf "%s\n") msgs
        with Not_found ->
            eprintf "no helpful documentation for %s\n" command

(* parse the global args up the first non option <command>
 * <exe> -opt1 -opt2 <command> <...>
 * *)
let parseGlobalArgs () =
    let printVersion () = printf "obuild %d.%d\n" major minor; exit 0
        in
    let printHelp () = printf "a rescue team has been dispatched\n";
                       exit 0
        in
    let expect_param1 optName l f =
        match l with
        | []    -> failwith (optName ^ " expect a parameter")
        | x::xs -> f x; xs
        in
    let rec processGlobalArgs l =
        match l with
        | x::xs -> if String.length x > 0 && x.[0] = '-'
                    then (
                        let retXs =
                            match x with
                            | "--help"    -> printHelp ()
                            | "--version" -> printVersion ()
                            | "--verbose" -> gconf.conf_verbosity <- Verbose; xs
                            | "--color"   -> gconf.conf_color <- true; xs
                            | "--debug"   -> gconf.conf_verbosity <- Debug; xs
                            | "--debug+"  -> gconf.conf_verbosity <- DebugPlus; xs
                            | "--debug-with-cmd" -> gconf.conf_verbosity <- DebugPlus; xs
                            | "--silent"  -> gconf.conf_verbosity <- Silent; xs
                            | "--strict"  -> gconf.conf_strict    <- true; xs
                            | "--findlib-conf" -> expect_param1 x xs (fun p -> gconf.conf_findlib_path <- Some p)
                            | "--ocamlopt" -> expect_param1 x xs (fun p -> gconf.conf_prog_ocamlopt <- Some p)
                            | "--ocamldep" -> expect_param1 x xs (fun p -> gconf.conf_prog_ocamldep <- Some p)
                            | "--ocamlc"   -> expect_param1 x xs (fun p -> gconf.conf_prog_ocamlc <- Some p)
                            | "--cc"       -> expect_param1 x xs (fun p -> gconf.conf_prog_cc <- Some p)
                            | "--ar"       -> expect_param1 x xs (fun p -> gconf.conf_prog_ar <- Some p)
                            | "--pkg-config"-> expect_param1 x xs (fun p -> gconf.conf_prog_pkgconfig <- Some p)
                            | "--ranlib"   -> expect_param1 x xs (fun p -> gconf.conf_prog_ranlib <- Some p)
                            | _           -> failwith ("unknown global option: " ^ x)
                            in
                         processGlobalArgs retXs
                    ) else
                         l
        | []    -> []
        in

    processGlobalArgs (List.tl (Array.to_list Sys.argv))

let knownCommands =
    [ ("configure", mainConfigure)
    ; ("build", mainBuild)
	; ("clean", mainClean)
	; ("sdist", mainSdist)
	; ("install", mainInstall)
	; ("init", mainInit)
	; ("test", mainTest)
	; ("doc", mainDoc)
	; ("help", mainHelp)
    ]

let defaultMain () =
    let args = parseGlobalArgs () in

    if List.length args = 0
    then (
        eprintf "usage: %s <command> [options]\n\n%s\n" Sys.argv.(0) usageCommands;
        exit 1
    );

    let cmd = List.nth args 0 in
    try
        let mainF = List.assoc cmd knownCommands in
        mainF args
    with Not_found ->
        eprintf "error: unknown command: %s\n\n  known commands:\n" cmd;
        List.iter (eprintf "    %s\n") (List.map fst knownCommands);
        exit 1

let () =
    try defaultMain ()
    with exn -> Exception.show exn
