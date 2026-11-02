%% @doc Command-line front end, built as an escript by `rebar3 escriptize'.
%%
%% ```
%% cellwork eval FILE.csv [--csv]   evaluate and print the grid (or CSV)
%% cellwork get FILE.csv REF        print one cell's value
%% cellwork check FILE.csv          list error cells; exit 1 if any
%% cellwork repl [FILE.csv]         interactive editing
%% '''
-module(cellwork).

-export([main/1, render/1, run/1]).

-spec main([string()]) -> no_return().
main(Args) ->
    {Code, Out} = run(Args),
    io:put_chars(Out),
    erlang:halt(Code).

%% @doc Run a non-interactive command and return `{ExitCode, Output}';
%% kept pure of I/O so it can be tested.
-spec run([string()]) -> {non_neg_integer(), iodata()}.
run(["eval", File]) -> with_sheet(File, fun(S) -> {0, render(S)} end);
run(["eval", File, "--csv"]) -> with_sheet(File, fun(S) -> {0, cell_csv:export_values(S)} end);
run(["get", File, Ref]) ->
    with_sheet(File, fun(S) ->
        case cell_ref:parse(Ref) of
            {ok, Pos} -> {0, [cell_sheet:display(S, Pos), $\n]};
            error -> {2, ["error: bad cell reference ", Ref, $\n]}
        end
    end);
run(["check", File]) ->
    with_sheet(File, fun(S) ->
        Errs = [{P, V} || {P, _, V} <- cell_sheet:cells(S), cell_value:is_error(V)],
        case Errs of
            [] -> {0, "ok: no errors\n"};
            _ -> {1, [[cell_ref:to_string(P), ": ", cell_value:display(V), $\n]
                      || {P, V} <- Errs]}
        end
    end);
run(["repl"]) -> repl(cell_sheet:new());
run(["repl", File]) -> with_sheet(File, fun repl/1);
run(Args) when Args =:= []; Args =:= ["help"]; Args =:= ["--help"]; Args =:= ["-h"] ->
    {0, usage()};
run(_) -> {2, usage()}.

usage() ->
    "usage:\n"
    "  cellwork eval FILE.csv [--csv]   evaluate and print the grid (or CSV)\n"
    "  cellwork get FILE.csv REF        print one cell's value\n"
    "  cellwork check FILE.csv          list error cells; exit 1 if any\n"
    "  cellwork repl [FILE.csv]         interactive editing\n".

with_sheet(File, Fun) ->
    case cell_csv:load_file(File) of
        {ok, S} -> Fun(S);
        {error, Reason} -> {2, ["error: ", describe(Reason), $\n]}
    end.

describe({file, Path, Reason}) -> [Path, ": ", file:format_error(Reason)];
describe({unterminated_quote, Line}) -> io_lib:format("unterminated quote starting on line ~b", [Line]);
describe({syntax, Pos, Msg}) -> [cell_ref:to_string(Pos), ": syntax error: ", Msg];
describe({bad_ref, Ref}) -> io_lib:format("bad cell reference ~p", [Ref]);
describe(Other) -> io_lib:format("~p", [Other]).

%% @doc Render the used area as a text grid with column letters and row
%% numbers. Numbers are right-aligned, everything else left-aligned.
-spec render(cell_sheet:sheet()) -> iodata().
render(Sheet) ->
    case cell_sheet:bounds(Sheet) of
        {0, 0} -> "(empty sheet)\n";
        {MC, MR} ->
            Cols = lists:seq(1, MC),
            Cells = [[{cell_sheet:get(Sheet, {C, R}), cell_sheet:display(Sheet, {C, R})}
                      || C <- Cols] || R <- lists:seq(1, MR)],
            Widths = [max(string:length(cell_ref:col_to_letters(C)),
                          lists:max([string:length(D) || D <- column(C, Cells)]))
                      || C <- Cols],
            RW = length(integer_to_list(MR)),
            Header = [lists:duplicate(RW, $\s),
                      [[" | ", pad(cell_ref:col_to_letters(C), W, left)]
                       || {C, W} <- lists:zip(Cols, Widths)], $\n],
            Rule = [lists:duplicate(RW, $-),
                    [["-+-", lists:duplicate(W, $-)] || W <- Widths], $\n],
            Body = [[pad(integer_to_list(R), RW, right),
                     [[" | ", pad(D, W, align(V))] || {{V, D}, W} <- lists:zip(Row, Widths)],
                     $\n]
                    || {R, Row} <- lists:zip(lists:seq(1, MR), Cells)],
            [Header, Rule, Body]
    end.

column(C, Rows) -> [element(2, lists:nth(C, Row)) || Row <- Rows].

align(V) when is_float(V) -> right;
align(_) -> left.

pad(S, W, Side) ->
    Fill = lists:duplicate(max(0, W - string:length(S)), $\s),
    case Side of
        left -> [S, Fill];
        right -> [Fill, S]
    end.

%% REPL --------------------------------------------------------------------

repl(Sheet) ->
    io:put_chars("cellwork repl. Type :help for commands.\n"),
    loop(Sheet),
    {0, ""}.

loop(Sheet) ->
    case io:get_line("> ") of
        eof -> ok;
        {error, _} -> ok;
        Line ->
            case command(string:trim(unicode:characters_to_list(Line)), Sheet) of
                quit -> ok;
                {Out, Sheet1} -> io:put_chars(Out), loop(Sheet1)
            end
    end.

command("", S) -> {"", S};
command(":quit", _) -> quit;
command(":q", _) -> quit;
command(":help", S) ->
    {"  A1 10          set a value      B1 =A1*2   set a formula\n"
     "  A1             clear a cell     :show      print the grid\n"
     "  :get A1        value and input  :deps A1   precedents and dependents\n"
     "  :save F.csv    save inputs      :quit      leave\n", S};
command(":show", S) -> {render(S), S};
command(":get " ++ Ref, S) ->
    on_ref(Ref, S, fun(P) ->
        {[cell_ref:to_string(P), " = ", cell_sheet:display(S, P),
          "   (input: ", cell_sheet:input(S, P), ")\n"], S}
    end);
command(":deps " ++ Ref, S) ->
    on_ref(Ref, S, fun(P) ->
        Names = fun(Ps) -> lists:join(", ", [cell_ref:to_string(X) || X <- Ps]) end,
        {["reads: ", Names(cell_sheet:precedents(S, P)), "\n",
          "read by: ", Names(cell_sheet:dependents(S, P)), "\n"], S}
    end);
command(":save " ++ File, S) ->
    case file:write_file(string:trim(File), cell_csv:export_inputs(S)) of
        ok -> {["saved ", string:trim(File), "\n"], S};
        {error, R} -> {["error: ", file:format_error(R), "\n"], S}
    end;
command(":" ++ _ = Cmd, S) -> {["unknown command ", Cmd, " (try :help)\n"], S};
command(Line, S) ->
    {Ref, Rest} = case string:split(Line, " ") of
                      [R] -> {R, ""};
                      [R, Input] -> {R, string:trim(Input, leading)}
                  end,
    on_ref(Ref, S, fun(P) ->
        case cell_sheet:set(S, P, Rest) of
            {ok, S1, Changed} ->
                {[[cell_ref:to_string(Pos), " = ", cell_value:display(V), "\n"]
                  || {Pos, V} <- Changed], S1};
            {error, Reason} ->
                {["error: ", describe(Reason), "\n"], S}
        end
    end).

on_ref(Ref, S, Fun) ->
    case cell_ref:parse(string:trim(Ref)) of
        {ok, P} -> Fun(P);
        error -> {["error: bad cell reference ", Ref, "\n"], S}
    end.
