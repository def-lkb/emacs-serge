open Sexp
open Session
open Tui

module Remote_textbuf = struct
  type revision = {
    r_remote: int;
    r_local: int;
  }

  type substitution = {
    start: int;
    length: int;
    replacement: string;
    raw: bool;
    action: bool;
  }

  type command =
    | Substitute of substitution
    | Click of int

  type command_stream = {
    mutable sink: t neg option;
    mutable closed: bool;
    mutable queue: (revision * command) list;
  }

  let sexp_of_revision {r_remote; r_local} =
    C (I r_remote, I r_local)

  let cons_if cond x xs = if cond then x :: xs else xs

  let send_command sink (rev,cmd) = match cmd with
    | Substitute {start; length; replacement; raw; action} ->
      let cmd = sexp_of_list (
          S "substitute" ::
          sexp_of_revision rev ::
          C (I start, I length) ::
          T replacement ::
          cons_if raw (S "raw") (cons_if action (S "action") [])
        )
      in
      sink (Feed cmd)
    | Click offset ->
      sink (Feed (sexp_of_list [
          S "click";
          sexp_of_revision rev;
          I offset
        ]))

  let replace_sink commands sink =
    begin match commands.sink with
      | Some sink' -> sink' (Quit sym_nil)
      | None -> ()
    end;
    commands.sink <- None;
    match sink with
    | Some f ->
      let rec aux = function
        | [] -> ()
        | ls ->
          commands.queue <- [];
          List.iter (send_command f) (List.rev ls);
          aux commands.queue
      in
      aux commands.queue;
      commands.sink <- sink
    | None -> ()

  type op =
    | R of int * int
    | I of int * int

  type t = {
    commands: command_stream;
    mutable textbuf: Tui.Textbuf.t;

    mutable remote: int;
    mutable latest_remote: int;

    mutable local: int;
    mutable revisions: (int * op) list;
    mutable rev_tail: (int * op) list;
  }

  let revision_of_textbuf { remote; local } =
    { r_local = local; r_remote = remote }

  let push_command t cmd =
    let cmd = (revision_of_textbuf t, cmd) in
    if t.commands.closed then ()
    else match t.commands.sink with
      | None -> t.commands.queue <- cmd :: t.commands.queue
      | Some sink ->
        t.latest_remote <- t.remote;
        send_command sink cmd

  let update_revisions t (local, remote) =
    t.remote <- remote;
    let rec filter = function
      | (local', _) :: xs when local' <= local -> filter xs
      | xs -> xs
    in
    let rec rev_filter acc = function
      | (local', _) as x :: xs when local' > local ->
        rev_filter (x :: acc) xs
      | _ -> acc
    in
    begin match filter t.rev_tail with
      | [] ->
        t.rev_tail <- rev_filter [] t.revisions;
        t.revisions <- []
      | xs ->
        t.rev_tail <- xs
    end;
    if t.latest_remote < remote - 16 then
      let subst = {start = 0; length = 0; raw = true;
                   replacement = ""; action = false} in
      push_command t (Substitute subst)

  let commute_remove (_,op') (s2, l2) = match op' with
    | R (s1, l1) ->
      let remap x =
        if x < s1 then
          x
        else if x > s1 + l1 then
          x - l1
        else s1
      in
      let e2 = s2 + l2 in
      let s2 = remap s2 and e2 = remap e2 in
      if e2 = s2 then
        raise Not_found
      else (s2, e2 - s2)
    | I (s1, l1) ->
      if s1 < s2 then
        (s2 + l1, l2)
      else if s1 >= s2 + l2 then
        (s2, l2)
      else
        (s2, l2 + l1)

  let commute_point (_,op') s2 = match op' with
    | R (s1, l1) ->
      if s2 < s1 then
        s2
      else if s2 >= s1 + l1 then
        (s2 - l1)
      else
        raise Not_found
    | I (s1, l1) ->
      if s1 <= s2 then
        (s2 + l1)
      else
        s2

  let commute_remote_op t op_kind op_arg =
    let flip f x y = f y x in
    let op_arg = List.fold_left (flip op_kind) op_arg t.rev_tail in
    let op_arg = List.fold_right op_kind t.revisions op_arg in
    op_arg

  let create () =
    let commands = {
      sink   = None;
      closed = false;
      queue  = [];
    } in
    let t = { commands; textbuf = Textbuf.null;
                   remote = 0; latest_remote = 0; local = 0;
                   revisions = []; rev_tail = [] };
    in
    let handler = M (Sink (function
        | Feed (C (S "sink", M (Sink sink))) ->
          (*Printf.eprintf "GOT SINK!\n";*)
          replace_sink commands (Some sink)
        | Feed (C (S "click", C (C (I local, I remote), I point))) ->
          update_revisions t (local, remote);
          begin match commute_remote_op t commute_point point with
            | exception Not_found -> ()
            | point ->
              Textbuf.click t.textbuf point
          end
        | Feed (C (S "substitute",
                   C (C (I local, I remote),
                      C (C (I start, I length),
                         C (T replacement, flags))))) ->
          update_revisions t (local, remote);
          begin match
              if length <> 0 then
                commute_remote_op t commute_remove (start, length)
              else
                commute_remote_op t commute_point start, 0
            with
            | exception Not_found -> ()
            | (start, length) ->
              let raw = sexp_mem (S "raw") flags in
              let clickable = sexp_mem (S "action") flags in
              Textbuf.change t.textbuf
                ~raw ~clickable start length replacement
          end
        | Feed r ->
          cancel r
        | Quit (S "close") ->
          replace_sink commands None;
          commands.closed <- true;
          ()
        | Quit _ -> ()
      ))
    in
    handler, t

  let change t text =
    let open Textbuf in
    t.local <- t.local + 1;
    if text.old_len <> 0 then
      t.revisions <- (t.local, R (text.position, text.old_len)) :: t.revisions;
    if text.new_len <> 0 then
      t.revisions <- (t.local, I (text.position, text.new_len)) :: t.revisions;
    push_command t
      (Substitute { start = text.position; length = text.old_len;
                    raw = text.text_raw; replacement = text.text;
                    action = text.clickable })

  let click t offset =
    push_command t (Click offset)

  let class_ = {
    Class.
    connect = (fun t buf -> t.textbuf <- buf);
    connected = ignore; change; click;
  }
end

let textbuf_session () =
  let session, t = Remote_textbuf.create () in
  session, Class.make_textbuf Remote_textbuf.class_ t

let cursor_greetings ~name =
  let cursor, a = Textbuf.with_cursor () in
  let session, b = textbuf_session () in
  Tui.Textbuf.connect ~a ~b;
  sexp_of_list [S "create-buffer"; T name; session], cursor

let accept_textbuf = function
  | M (Sink t) ->
    let session, textbuf = textbuf_session () in
    t (Feed (C (S "accept", session)));
    textbuf, (fun str -> t (Feed (C (S "title", T str))))
  | _ -> invalid_arg "Stui.accept_textbuf"

let accept_cursor session =
  let a, set_title = accept_textbuf session in
  let cursor, b = Textbuf.with_cursor () in
  Tui.Textbuf.connect ~a ~b;
  cursor, set_title
