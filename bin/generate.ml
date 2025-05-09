(*
 * Copyright (c) 2021 Magnus Skjegstad <magnus@skjegstad.com>
 * Copyright (c) 2021 Thomas Gazagnaire <thomas@gazagnaire.org>
 * Copyright (c) 2021 Patrick Ferris <pf341@patricoferris.com>
 * Copyright (c) 2021 Tim McGilchrist <timmcgil@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Okra
open Cmdliner
module Cal = CalendarLib.Calendar

(* Calendar term *)

let week_term =
  Arg.value
  @@ Arg.opt Arg.(some int) None
  @@ Arg.info ~doc:"The week of the year defaulting to the current week"
       ~docv:"WEEK" [ "week" ]

let weeks_term =
  Arg.value
  @@ Arg.opt Arg.(some (pair ~sep:'-' int int)) None
  @@ Arg.info ~doc:"A range specified by a start and end week (inclusive)"
       ~docv:"WEEK" [ "weeks" ]

let month_term =
  Arg.value
  @@ Arg.opt Arg.(some int) None
  @@ Arg.info
       ~doc:
         "The month of the year defaulting to the current month (January = 1)"
       ~docv:"MONTH" [ "m"; "month" ]

let year_term =
  Arg.value
  @@ Arg.opt Arg.(some int) None
  @@ Arg.info ~doc:"The year defaulting to the current year" ~docv:"YEAR"
       [ "y"; "year" ]

let no_links_term =
  Arg.value
  @@ Arg.flag
  @@ Arg.info ~doc:"Generate shortened GitHub style urls" ~docv:"NO_LINKS"
       [ "no-links" ]

(* Report printing configuration *)

let with_names_term =
  Arg.value
  @@ Arg.flag
  @@ Arg.info ~doc:"Adds names of authors to a generated report"
       ~docv:"WITH_NAMES" [ "with-names" ]

let with_times_term =
  Arg.value
  @@ Arg.flag
  @@ Arg.info ~doc:"Adds times or PRs/Issues to a generated report"
       ~docv:"WITH_TIMES" [ "with-times" ]

let with_descriptions_term =
  Arg.value
  @@ Arg.flag
  @@ Arg.info ~doc:"Adds the body of the Issue/PR to the report"
       ~docv:"WITH_DESCRIPTIONS" [ "with-descriptions" ]

let calendar_term : Calendar.t Term.t =
  let open Let_syntax_cmdliner in
  let+ week = week_term
  and+ weeks = weeks_term
  and+ month = month_term
  and+ year = year_term in
  match (week, weeks, month, year) with
  | None, None, None, year -> Calendar.of_week ?year (Cal.now () |> Cal.week)
  | Some week, _, _, year -> Calendar.of_week ?year week
  | None, Some range, _, year -> Calendar.of_week_range ?year range
  | None, None, Some month, year -> Calendar.of_month ?year month

(* The kind of report we are generating
     - engineer: a report for an individual engineer
     - reposiories: 1 or more repository contributions *)

type kind = Engineer | Repository

let kind_term =
  Arg.value
  @@ Arg.opt
       Arg.(enum [ ("engineer", Engineer); ("repository", Repository) ])
       Engineer
  @@ Arg.info ~doc:"The kind of report you would like to generate." ~docv:"KIND"
       [ "k"; "kind" ]

let repositories =
  Arg.value
  @@ Arg.pos_all Arg.string []
  @@ Arg.info
       ~doc:
         "A list of repositories to generate reports for (only for \
          kind=repository)"
       ~docv:"REPOSITORIES" []

let no_activity =
  Arg.value
  @@ Arg.flag
  @@ Arg.info
       ~doc:
         "The --no-activity flag will disable any attempt to generate activity \
          reports from Github"
       ~docv:"NO-ACTIVITY" [ "no-activity" ]

let with_repositories_term =
  Arg.value
  @@ Arg.opt Arg.(list string) []
  @@ Arg.info
       ~doc:
         "Specify a list of Github repositories (e.g. ocaml/opam-repository) \
          to get your merges from. This is probably only useful for people who \
          spend time merging PRs but not explicitly reviewing them so the \
          activity won't appear normally (or creating the PR)"
       [ "include-repositories" ]

(* Get activity configuration *)
let home =
  match Sys.getenv_opt "HOME" with
  | None -> Fmt.failwith "$HOME is not set!"
  | Some dir -> dir

let default_token_file =
  let ( / ) = Filename.concat in
  home / ".github" / "github-activity-token"

let token =
  Arg.value
  @@ Arg.opt Arg.file default_token_file
  @@ Arg.info
       ~doc:
         "The path to a file containing your github token, defaults to \
          ~/.github/github-activity-token"
       ~docv:"TOKEN" [ "t"; "token" ]

module Fetch = Get_activity.Contributions.Fetch (Cohttp_lwt_unix.Client)
module Repo_fetch = Okra.Repo_report.Make (Cohttp_lwt_unix.Client)

module Time = struct
  let now = Unix.gettimeofday
  let sleep = Lwt_unix.sleep
end

module Env = struct
  let debug = try Unix.getenv "GITLAB_DEBUG" <> "0" with _ -> false

  let gitlab_uri =
    try Unix.getenv "GITLAB_URL" with _ -> "https://gitlab.com/api/v4"
end

module Gitlab = Activity.Gitlab.Fetch (Env) (Time) (Cohttp_lwt_unix.Client)

let fetch ~token ~period =
  let after, before = Okra.Calendar.to_gitlab period in
  let token = Gitlab.G.Token.of_string token in
  Gitlab.make_activity ~token ~before ~after

let run_engineer conf cal projects token no_activity no_links with_repositories
    =
  let open Lwt.Syntax in
  let period = Calendar.to_iso8601 cal in
  let week = Calendar.week cal in
  let activity, _ =
    if no_activity then
      ( Get_activity.Contributions.
          { username = "<USERNAME>"; activity = Repo_map.empty },
        [] )
    else
      let contributions () =
        let+ fetch = Fetch.exec ~period ~token
        and+ report =
          (* When a user specifies `with_repositories` we also fetch reports
             from these repositories and filter the PRs made over the same
             time period that were merged by the user returned by fetching
             the original get-activity. *)
          if with_repositories = [] then
            Lwt.return Repo_report.Project_map.empty
          else Repo_fetch.get ~period ~token with_repositories
        in
        let contribs =
          Get_activity.Contributions.of_json ~from:(fst period) fetch
        in
        let merges =
          let bindings = Repo_report.Project_map.bindings report in
          List.map
            (fun (_, v) ->
              List.filter
                (fun pr -> Some contribs.username = pr.Repo_report.PR.merged_by)
                v.Repo_report.prs)
            bindings
        in
        (contribs, List.concat merges)
      in
      Lwt_main.run (contributions ())
  in
  let gitlab_activity =
    let open Gitlab.G.Monad in
    match Conf.gitlab_token conf with
    | Some token ->
        let main () =
          let+ events = fetch ~token ~period:cal in
          Activity.Gitlab.to_repo_map events
        in
        Lwt_main.run @@ Gitlab.G.Monad.run (main ())
    | None -> Get_activity.Contributions.Repo_map.empty
  in
  let from, to_ = Calendar.range cal in
  let format_date f = CalendarLib.Printer.Date.fprint "%0Y/%0m/%0d" f in
  let header =
    Fmt.str "%s week %i: %a -- %a" activity.username week format_date from
      format_date to_
  in
  let pp_footer ppf conf = Fmt.(pf ppf "\n\n%a" string conf) in
  let activity = Activity.make ~projects activity in
  Fmt.(
    pr "%s\n\n%a%a%a" header (Activity.pp ~no_links ()) activity
      (Activity.pp_activity ~gitlab:true ~no_links:false ())
      gitlab_activity (option pp_footer) (Conf.footer conf))

let get_or_error = function
  | Ok v -> v
  | Error (`Msg m) ->
      Fmt.epr "%s" m;
      exit 1

let run_monthly cal repos token with_names with_times with_descriptions =
  let from, to_ = Calendar.range cal in
  let format_date f = CalendarLib.Printer.Date.fprint "%0Y/%0m/%0d" f in
  let period = Calendar.to_iso8601 cal in
  let projects = Lwt_main.run (Repo_fetch.get ~period ~token repos) in
  Fmt.(
    pf stdout "# Reports (%a - %a)\n\n%a" format_date from format_date to_
      (Repo_report.pp ~with_names ~with_times ~with_descriptions)
      projects)

let run cal okra_conf token no_activity no_links with_names with_times
    with_descriptions with_repositories repos = function
  | Engineer ->
      run_engineer okra_conf cal (Conf.projects okra_conf) token no_activity
        no_links with_repositories
  | Repository ->
      run_monthly cal repos token with_names with_times with_descriptions

let term =
  let open Let_syntax_cmdliner in
  let+ cal = calendar_term
  and+ token_file = token
  and+ no_activity = no_activity
  and+ with_repositories = with_repositories_term
  and+ kind = kind_term
  and+ no_links = no_links_term
  and+ with_names = with_names_term
  and+ with_times = with_times_term
  and+ with_descriptions = with_descriptions_term
  and+ repos = repositories
  and+ okra_conf = Common.conf
  and+ () = Common.setup () in
  let token =
    (* If [no_activity] is specfied then the token will not be used, don't try
       to load the file in that case *)
    if no_activity then ""
    else get_or_error @@ Get_activity.Token.load token_file
  in
  run cal okra_conf token no_activity no_links with_names with_times
    with_descriptions with_repositories repos kind

let cmd =
  let info =
    Term.info "generate"
      ~doc:"Generate an initial weekly report based on Github activity"
      ~man:
        [
          `S Manpage.s_description;
          `P
            "The generate command produces markdown reports using activity \
             from Github. There are two kinds of report that can be generated: \
             an engineer report and a repository report. The former shows your \
             individual activity for a given period and the latter shows \
             activity for a given set of repositories.";
          `P
            "See the options below for changing things like which week to \
             query for and where to find your token. To generate a token see \
             the README at https://github.com/talex5/get-activity.";
        ]
  in
  (term, info)
