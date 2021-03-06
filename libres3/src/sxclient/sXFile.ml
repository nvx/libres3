(**************************************************************************)
(*  SX client                                                             *)
(*  Copyright (C) 2012-2015 Skylable Ltd. <info-copyright@skylable.com>   *)
(*                                                                        *)
(*  This library is free software; you can redistribute it and/or         *)
(*  modify it under the terms of the GNU Lesser General Public            *)
(*  License as published by the Free Software Foundation; either          *)
(*  version 2.1 of the License, or (at your option) any later version.    *)
(*                                                                        *)
(*  This library is distributed in the hope that it will be useful,       *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *)
(*  Lesser General Public License for more details.                       *)
(*                                                                        *)
(*  You should have received a copy of the GNU Lesser General Public      *)
(*  License along with this library; if not, write to the Free Software   *)
(*  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,            *)
(*  MA  02110-1301  USA                                                   *)
(*                                                                        *)
(*  As a special exception to the GNU Library General Public License,     *)
(*  you may link, statically or dynamically, a "work that uses the        *)
(*  Library" with a publicly distributed version of the Library to        *)
(*  produce an executable file containing portions of the Library, and    *)
(*  distribute that executable file under terms of your choice, without   *)
(*  any of the additional requirements listed in clause 6 of the GNU      *)
(*  Library General Public License. By "a publicly distributed version    *)
(*  of the Library", we mean either the unmodified Library, or a          *)
(*  modified version of the Library that is distributed under the         *)
(*  conditions defined in clause 3 of the GNU Library General Public      *)
(*  License. This exception does not however invalidate any other         *)
(*  reasons why the executable file might be covered by the GNU Library   *)
(*  General Public License.                                               *)
(**************************************************************************)

open Lwt
module OS = EventIO.OS
type state = string * int ref
type read_state = unit
let scheme = "file"
let syntax = Hashtbl.find Neturl.common_url_syntax "file"

let file url =
  match Neturl.split_path (Neturl.local_path_of_file_url url) with
  | [""] -> "", ""
  | "" :: volume :: path ->
    let path = Neturl.join_path path in
    volume, path
  | path -> failwith ("Bad path: " ^ (Neturl.join_path path))
module IO = SXDefaultIO

module StringMap = Map.Make(String)
let volumes = ref StringMap.empty

let token_of_user _ = return (Some !Config.secret_access_key)
let invalidate_token_of_user _ = ()
let check _ = return None

let find name m =
  try return (StringMap.find name m)
  with Not_found -> fail (Unix.Unix_error(Unix.ENOENT, "find", name))

let etag_cnt = ref 0
let open_source url =
  let vol, name = file url in
  find vol !volumes >>= fun volume ->
  find name volume >>= fun (meta, _, contents) ->
  return (meta, (contents, ref 0))

let seek ((_, fpos) as s) ?len pos =
  fpos := Int64.to_int pos;
  return (s, ())

let read ((contents, fpos),_) =
  (* TODO: check that there is only one read in-flight on this fd? *)
  let pos = !fpos in
  let last = min (pos + Config.buffer_size) (String.length contents) in
  let amount = last - pos in
  fpos := last;
  return (contents, pos, amount)

let close_source _ = return ()

let copy_same ?metafn ?filesize _ _ =
  return false (* no optimized copy, fallback to generic *)

let delete ?async ?(recursive=false) url =
  match file url with
  | vol, ("" | "/") ->
    find vol !volumes >>= fun volume ->
    if StringMap.is_empty volume then begin
      volumes := StringMap.remove vol !volumes;
      return ()
    end else
      fail (Unix.Unix_error(Unix.ENOTEMPTY, "delete", vol))
  | vol, path ->
    find vol !volumes >>= fun volume ->
    (if recursive then return ()
    else find path volume >>= fun _ -> return ()) >>= fun () ->
    let volume =
      if recursive then begin
        StringMap.filter (fun p _ ->
            String.length p < String.length path ||
            String.sub p 0 (String.length path) <> path
          ) volume
      end
      else StringMap.remove path volume in
    volumes := StringMap.add vol volume !volumes;
    return ()

let exists url =
  match file url with
  | vol, (""|"/") ->
    return (StringMap.mem vol !volumes)
  | vol, path ->
    find vol !volumes >>= fun volume ->
    return (StringMap.mem path volume)

let is_prefix ~prefix str =
  let plen = String.length prefix in
  (String.length str) >= plen &&
  (String.sub str 0 plen) = prefix;;

let filter_fold f prefix accum entry =
  if is_prefix ~prefix entry.IO.name then begin
    f accum entry
  end
  else return accum

let filter_recurse recurse prefix dir =
  if is_prefix ~prefix dir then
    recurse dir
  else
    false;;

let fold_list url ?etag ?marker ?limit ?no_recurse f recurse accum =
  let vol, path = file url in
  if vol = "" then begin
    StringMap.iter (fun vol _ ->
        ignore (recurse ("/" ^ vol))) !volumes;
    return { SXDefaultIO.dir_etag = None; data = accum; }
  end else
    find vol !volumes >>= fun volume ->
    StringMap.fold (fun _ (e,_,_) accum ->
        accum >>= fun accum -> filter_fold f path accum e
      ) volume (return accum) >>= fun accum ->
    return { SXDefaultIO.dir_etag = None; data = accum }

let acl_table = Hashtbl.create 16

let create ?metafn ?replica url =
  match file url with
  | vol, ("" | "/") ->
    if StringMap.mem vol !volumes then
      fail (Unix.Unix_error(Unix.EEXIST, "create", vol))
    else begin
      volumes := StringMap.add vol StringMap.empty !volumes;
      Hashtbl.replace acl_table url [`Grant, `UserName !Config.key_id,
                                     [`Owner;`Manager;`Read;`Write]];
      return ();
    end
  | vol, path ->
    find vol !volumes >>= fun volume ->
    incr etag_cnt;
    let entry = {
      IO.name = "/" ^ Netencoding.Url.encode vol ^ path;
      size = 0L;
      mtime = Unix.gettimeofday ();
      etag = string_of_int !etag_cnt;
    }, [], "" in
    volumes := StringMap.add vol (StringMap.add path entry volume) !volumes;
    return ()

let get_meta url : (string*string) list Lwt.t =
  let vol, path = file url in
  find vol !volumes >>= fun volume ->
  find path volume >>= fun (_, meta, _) ->
  return meta

let set_meta url meta =
  let vol, path = file url in
  find vol !volumes >>= fun volume ->
  let entry = {
    IO.name="";
    size=0L;
    mtime=0.;
    etag=""
  }, meta, "" in
  volumes := StringMap.add vol (StringMap.add path entry volume) !volumes;
  return ()

let etag_cnt = ref 0

let put ?quotaok ?metafn ?async src srcpos dsturl =
  let vol, path = file dsturl in
  find vol !volumes >>= fun volume ->
  incr etag_cnt;
  let meta = begin match metafn with
    | None -> []
    | Some f -> f ()
  end in
  src.IO.seek srcpos >>= fun stream ->
  let buf = Buffer.create 128 in
  IO.iter stream (fun (str,pos,len) ->
      Buffer.add_substring buf str pos len;
      return ()) >>= fun () ->
  let contents = Buffer.contents buf in
  let entry = {
    IO.name = "/" ^ Netencoding.Url.encode vol ^ path;
    size = Int64.of_int (String.length contents);
    mtime = Unix.gettimeofday ();
    etag = string_of_int !etag_cnt
  }, meta, contents in
  volumes := StringMap.add vol (StringMap.add path entry volume) !volumes;
  begin match quotaok with
  | Some fn -> fn ()
  | None -> ()
  end;
  return ()

let users = ref []
let create_user (_:Neturl.url) (name:string) =
  users := name :: !users;
  return ""


let get_acl url = return (Hashtbl.find acl_table url)
let set_acl (url:Neturl.url) (acls : IO.acl list) =
  Hashtbl.replace acl_table url acls;
  return ()

let libres3_private = ref ""

let with_private_settings url ~max_wait f key =
  if key = "libres3_private" then begin
    f !libres3_private >>= function
    | Some r -> libres3_private := r; return ()
    | None -> return ()
  end else
    failwith "bad settings key"



