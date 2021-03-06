(**************************************************************************)
(*  LibreS3 server                                                        *)
(*  Copyright (C) 2012-2015 Skylable Ltd. <info-copyright@skylable.com>   *)
(*                                                                        *)
(*  This program is free software; you can redistribute it and/or modify  *)
(*  it under the terms of the GNU General Public License version 2 as     *)
(*  published by the Free Software Foundation.                            *)
(*                                                                        *)
(*  This program is distributed in the hope that it will be useful,       *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU General Public License for more details.                          *)
(*                                                                        *)
(*  You should have received a copy of the GNU General Public License     *)
(*  along with this program; if not, write to the Free Software           *)
(*  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,            *)
(*  MA 02110-1301 USA.                                                    *)
(*                                                                        *)
(*  Special exception for linking this software with OpenSSL:             *)
(*                                                                        *)
(*  In addition, as a special exception, Skylable Ltd. gives permission   *)
(*  to link the code of this program with the OpenSSL library and         *)
(*  distribute linked combinations including the two. You must obey the   *)
(*  GNU General Public License in all respects for all of the code used   *)
(*  other than OpenSSL. You may extend this exception to your version     *)
(*  of the program, but you are not obligated to do so. If you do not     *)
(*  wish to do so, delete this exception statement from your version.     *)
(**************************************************************************)

open Site
open Ocsigen_config
open CodedIO
open UnixLabels

let name = "libres3"
type config = {
  logdir: string option ref;
  datadir: string ref;
  uploaddir: string ref;
  commandpipe: string ref;
  timeout: int ref;
  keepalivetimeout: int ref;
}

let not_empty s = String.length !s > 0

let str_entry ?ns name ?attrs value =
  Xml.tag ?ns name ?attrs [Xml.d !value];;

let str_entry_opt ?ns name ?attrs value =
  match !value with
  | Some s ->
    Xml.tag ?ns name ?attrs [Xml.d s]
  | None ->
    Xml.d "";;

let int_entry ?ns name ?attrs value =
  Xml.tag ?ns name ?attrs [Xml.d (string_of_int !value)];;

let int_entry_opt ?ns name ?attrs value =
  match !value with
  | Some v ->
    Xml.tag ?ns name ?attrs [Xml.d (string_of_int v)]
  | None ->
    Xml.d ""

let set_default stref default =
  if !stref = "" then
    stref := default;;

let build_port port =
  ref (match !Configfile.base_listen_ip with
      | None -> string_of_int !port
      | Some (Ipaddr.V4 v4) ->
        Printf.sprintf "%s:%d" (Ipaddr.V4.to_string v4) !port
      | Some (Ipaddr.V6 v6) ->
        Printf.sprintf "[%s]:%d" (Ipaddr.V6.to_string v6) !port)

let build_ssl_config () =
  match !Configfile.ssl_certificate_file, !Configfile.ssl_privatekey_file with
  | Some cert, Some key ->
    [
      str_entry "port" ~attrs:[Xml.attr "protocol" "HTTPS"]
        (build_port Configfile.base_ssl_port);
      Xml.tag "ssl" [
        str_entry "certificate" (ref cert);
        str_entry "privatekey" (ref key)
      ];
    ]
  | _ -> [];;

let build_config conf =
  Xml.tag "ocsigen" [
    Xml.tag "server" (List.rev_append (build_ssl_config ()) [
        str_entry "port" (build_port Configfile.base_port);
        str_entry_opt "syslog" Configfile.syslog_facility;
        str_entry_opt "logdir" conf.logdir;
        str_entry "datadir" conf.datadir;
        str_entry "uploaddir" conf.uploaddir;
        str_entry_opt "user" Configfile.user;
        str_entry_opt "group" Configfile.group;
        str_entry "commandpipe" conf.commandpipe;
        str_entry "charset" (ref "utf-8");
        Xml.tag "maxrequestbodysize" [
          Xml.d (Printf.sprintf "%dMiB" !Configfile.maxrequestbodysize)
        ];
        str_entry "mimefile" Configfile.mimefile;
        int_entry "maxconnected" Configfile.max_connected;
        int_entry "servertimeout" Configfile.timeout;
        int_entry "clienttimeout" Configfile.keepalivetimeout;
        int_entry "shutdowntimeout" Configfile.shutdowntimeout;
        int_entry "netbuffersize" Configfile.netbuffersize;
        int_entry "filebuffersize" Configfile.filebuffersize;
        int_entry_opt "minthreads" Configfile.min_threads;
        int_entry_opt "maxthreads" Configfile.max_threads;
        int_entry_opt "maxdetachedcomputationsqueued" Configfile.maxdetachedcomputationsqueued;
        int_entry "maxretries" Configfile.maxretries;
        Xml.tag "extension" ~attrs:[Xml.attr "name" "libres3"] [];
        Xml.tag "usedefaulthostname" [];
        Xml.tag "host" ~attrs:[Xml.attr "defaulthostname" !(Configfile.base_hostname)] [
          Xml.tag "libres3" [];
        ];
      ])
  ];;

let write_config filech xml =
  let output = Xmlm.make_output ~nl:true (`Channel filech) in
  Xmlm.output_doc_tree (fun (x:Xml.t) -> x) output (None,xml);;

let try_chown dirname =
  match !Configfile.user with
  | Some u ->
    begin try
        let pw = getpwnam u in
        chown dirname ~uid:pw.pw_uid ~gid:pw.pw_gid
      with
      | Not_found | Unix_error(EPERM,_,_) -> ()
    end
  | None -> ()
;;

let rec mkdir_p dir ~perm =
  begin try
      mkdir dir ~perm;
    with
    | Unix_error(ENOENT,_,_) ->
      mkdir_p (Filename.dirname dir) ~perm;
      mkdir dir ~perm;
    | Unix_error(EEXIST,_,_) -> ()
  end;
  try_chown dir
;;

let print_version () =
  Printf.printf "libres3 version %s\n%!" Version.version;
  exit 0
;;

let handle_error f () =
  try
    f ()
  with
  | Unix_error (err, fn, param) ->
    Printf.eprintf "Error in %s(%s): %s\n%!" fn param (error_message err);
    exit 2
  | Sys_error msg ->
    Printf.eprintf "Error: %s\n%!" msg;
    exit 3
  | Failure msg ->
    Printf.eprintf "Error: %s\n%!" msg;
    exit 4
  | e ->
    Printf.eprintf "Unexpected error: %s\n%!" (Printexc.to_string e);
    exit 5
;;

let handle_signal s msg =
  ignore (
    Lwt_unix.on_signal s (fun _ ->
        ignore (write UnixLabels.stdout ~buf:msg ~pos:0 ~len:(String.length msg));
        exit 3;
      )
  );;

let pinged = ref false

let rec wait_pipe file delay pipe_read =
  if delay <= 0. then false
  else try
      let fd = openfile file ~mode:[O_RDWR] ~perm:0 in
      let buf = "libres3:ping\n" in
      ignore (write fd ~buf ~pos:0 ~len:(String.length buf));
      close fd;
      match select ~read:[pipe_read] ~write:[] ~except:[] ~timeout:0.1 with
      | [], _, _ -> wait_pipe file (delay -. 0.1) pipe_read
      | _ ->
        let buf = String.make 1 ' ' in
        ignore (read pipe_read ~buf ~pos:0 ~len:1);
        buf = "X"
    with Unix_error(ENOENT,_,_) ->
      Netsys.sleep 0.1;
      wait_pipe file (delay -. 0.1) pipe_read;;

let list_of_opt ptr = match !ptr with
  | Some v -> [ref v]
  | None -> []

let enable_debug () =
  Lwt_log.Section.set_level EventLog.section Lwt_log.Debug

let initialize config pipe =
  let stop = ref false and status = ref false and reload = ref false in
  let extra_spec = [
    "--foreground", Arg.Clear Configfile.daemonize, " Run in foreground mode (default: \
                                                     daemonize)";
    "--stop", Arg.Set stop, " Stop running process (based on PIDfile)";
    "--reload", Arg.Set reload, " Reload running process configuration (based on PIDfile)";
    "--status", Arg.Set status, " Print running process status (based on PIDfile)";
    "--debug", Arg.Unit enable_debug, " Turn on verbose/debug messages";
  ] in

  Cmdline.parse_cmdline extra_spec;
  let conf = Cmdline.load_configuration Configfile.entries in
  if !stop then begin
    Pid.kill_pid !Configfile.pidfile;
    exit 0
  end;
  if !reload then begin
    Pid.sighup_pid !Configfile.pidfile;
    exit 0
  end;
  if !status then begin
    Pid.print_status !Configfile.pidfile;
    exit 0
  end;
  begin match !Configfile.ssl_certificate_file, !Configfile.ssl_privatekey_file with
    | None, None ->
      Config.sx_ssl := false;
      let msg = "Running in INSECURE mode. It is recommended that you enable SSL instead!" in
      Ocsigen_messages.console (fun () -> msg);
      Ocsigen_messages.warning msg;
    | _ -> ()
  end;
  Cmdline.validate_configuration conf;

  config.logdir :=
    if !Configfile.syslog_facility = None then Some !Paths.log_dir else None;
  let dir = match !Configfile.tmpdir with
    | Some tmpdir ->
      let d = Filename.concat tmpdir "libres3" in
      mkdir_p ~perm:0o750 d;
      Netsys_tmp.set_tmp_directory d;
      d
    | None -> Paths.var_lib_dir in
  set_default config.datadir (Filename.concat dir "datadir");
  set_default config.uploaddir (Filename.concat dir "uploaddir");
  set_default config.commandpipe (Filename.concat dir "command.pipe");
  set_disablepartialrequests true;(* we handle it ourselves *)
  set_maxuploadfilesize (Some  5368709120L);
  set_respect_pipeline ();
  set_filebuffersize Config.buffer_size;
  set_netbuffersize !Configfile.netbuffersize;
  Lwt_io.set_default_buffer_size !Configfile.netbuffersize;
  let rundir = Filename.dirname !Configfile.pidfile in
  List.iter (fun d -> mkdir_p ~perm:0o770 !d)
    (ref rundir :: config.datadir :: config.uploaddir :: list_of_opt config.logdir);
  let configfile = Paths.generated_config_file in
  let ch = open_out configfile in
  write_config ch (build_config config);
  close_out ch;
  set_configfile configfile;

  register_all pipe;
;;

let command_pipe = Filename.concat Paths.var_lib_dir "command.pipe"

let reopen_logs _ =
  try
    Lwt.async (fun () -> Accesslog.reopen ());
    let f = open_out command_pipe in
    begin try output_string f "reopen_logs\n" with _ -> () end;
    close_out f
  with _ ->
    ()

let run_server commandpipe =
  Pid.write_pid !Configfile.pidfile;
  begin try unlink commandpipe with _ -> () end;
  if !Configfile.daemonize then begin
    let dev_null = Unix.openfile "/dev/null" [Unix.O_RDWR] 0o666 in
    Unix.dup2 dev_null Unix.stdin;
    Unix.dup2 dev_null Unix.stdout;
    Unix.dup2 dev_null Unix.stderr;
    Unix.close dev_null
  end;
  Lwt_main.at_exit (fun () -> Lwt_unix.with_timeout 5. Lwt_unix.wait_for_jobs);
  handle_signal Sys.sigint "Exiting due to user interrupt";
  handle_signal Sys.sigterm "Exiting due to TERM signal";
  Ocsigen_server.start_server ();
  exit 0

let run () =
  Configfile.max_connected := 350;
  ignore (Sys.signal Sys.sighup Sys.Signal_ignore);

  Arg.current := 0;
  let config = {
    logdir = ref (Some "");
    datadir = ref "";
    uploaddir = ref "";
    commandpipe = ref "";
    timeout = ref 30;
    keepalivetimeout = ref 30;
  } in

  let pipe_read, pipe_write = Unix.pipe () in
  initialize config pipe_write;
  flush_all ();
  Sys.set_signal Sys.sigchld (Sys.Signal_handle (fun _ ->
      Printf.eprintf "\nFailed to start server (check logfile: %s/errors.log)\n%!" (!Paths.log_dir);
      exit 1
    ));
  ignore (Lwt_unix.on_signal Sys.sigusr1 reopen_logs);
  let ok = ref false in
  at_exit (fun () ->
      if not !ok then begin
        ok := true;
        let msg = "Killing all children\n" in
        ignore (write UnixLabels.stdout ~buf:msg ~pos:0 ~len:(String.length msg));
        (* kill self&all children *)
        Unix.sleep 1;
        Unix.kill 0 15
      end
    );
  Lwt_unix.set_pool_size !Configfile.max_pool_threads;
  Gc.compact ();
  if !Configfile.daemonize then begin
    Unix.chdir "/";
    ignore (Unix.setsid ());
    if Lwt_unix.fork () > 0 then begin
      (* Do not run exit hooks in the parent. *)
      Lwt_sequence.iter_node_l Lwt_sequence.remove Lwt_main.exit_hooks;
    end else begin
      ignore (Unix.setsid ());
      run_server !(config.commandpipe)
    end
  end else begin
    if Lwt_log.Section.level EventLog.section > Lwt_log.Notice then
      Lwt_log.Section.set_level EventLog.section Lwt_log.Notice;
    run_server !(config.commandpipe)
  end;
  Printf.printf "Waiting for server to start (5s) ... %!";
  begin try Unix.close pipe_write with _ -> () end;
  if wait_pipe !(config.commandpipe) 5. pipe_read then begin
    Printf.printf "OK\n%!";
    ok := true;
  end else begin
    Printf.printf "still didn't start!\n%!";
    exit 1
  end
;;

let () =
  Printexc.record_backtrace true;
  Printexc.register_printer (function
      | Ocsigen_stream.Interrupted e ->
        Some ("Ocsigen_stream.Interrupted: " ^ (Printexc.to_string e))
      | _ -> None
    );
  handle_error run ();;
