%% @doc RFC 4180 CSV reading and writing, plus loading CSV grids into a
%% sheet (row N column M of the file becomes the cell at column M row N).
-module(cell_csv).

-export([parse/1, encode/1, load/1, load_file/1,
         export_values/1, export_inputs/1]).

%% @doc Parse CSV text into rows of binary fields. Handles quoted fields
%% with embedded commas, quotes (`""') and newlines, and CRLF or LF line
%% endings. A trailing newline does not produce an empty row.
-spec parse(iodata()) -> {ok, [[binary()]]} | {error, {unterminated_quote, pos_integer()}}.
parse(Data) ->
    Bin = iolist_to_binary(Data),
    try {ok, rows(Bin, 1, [], [], [])}
    catch throw:{unterminated_quote, Line} -> {error, {unterminated_quote, Line}}
    end.

rows(<<>>, _L, [], [], Rows) -> lists:reverse(Rows);
rows(<<>>, _L, Field, Row, Rows) -> lists:reverse([end_row(Field, Row) | Rows]);
rows(<<"\r\n", Rest/binary>>, L, F, R, Rows) -> rows(Rest, L + 1, [], [], [end_row(F, R) | Rows]);
rows(<<"\n", Rest/binary>>, L, F, R, Rows) -> rows(Rest, L + 1, [], [], [end_row(F, R) | Rows]);
rows(<<",", Rest/binary>>, L, F, R, Rows) -> rows(Rest, L, [], [field(F) | R], Rows);
rows(<<"\"", Rest/binary>>, L, [], R, Rows) ->
    {Quoted, Rest1, L1} = quoted(Rest, L, L, []),
    rows(Rest1, L1, {quoted, Quoted}, R, Rows);
rows(<<C/utf8, Rest/binary>>, L, F, R, Rows) when is_list(F) ->
    rows(Rest, L, [<<C/utf8>> | F], R, Rows);
rows(<<C/utf8, Rest/binary>>, L, {quoted, Q}, R, Rows) ->
    %% Text after a closing quote is kept, as most readers do.
    rows(Rest, L, [<<C/utf8>>, Q], R, Rows);
rows(<<B, Rest/binary>>, L, F, R, Rows) ->
    %% Not valid UTF-8: keep the raw byte.
    F1 = case F of {quoted, Q} -> [Q]; _ -> F end,
    rows(Rest, L, [<<B>> | F1], R, Rows).

quoted(<<"\"\"", Rest/binary>>, Start, L, Acc) -> quoted(Rest, Start, L, [$" | Acc]);
quoted(<<"\"", Rest/binary>>, _Start, L, Acc) -> {iolist_to_binary(lists:reverse(Acc)), Rest, L};
quoted(<<"\n", Rest/binary>>, Start, L, Acc) -> quoted(Rest, Start, L + 1, [$\n | Acc]);
quoted(<<C, Rest/binary>>, Start, L, Acc) -> quoted(Rest, Start, L, [C | Acc]);
quoted(<<>>, Start, _L, _Acc) -> throw({unterminated_quote, Start}).

field({quoted, Q}) -> Q;
field(F) -> iolist_to_binary(lists:reverse(F)).

end_row(F, R) -> lists:reverse([field(F) | R]).

%% @doc Encode rows as CSV with LF line endings, quoting only when needed.
-spec encode([[iodata()]]) -> binary().
encode(Rows) ->
    iolist_to_binary([[lists:join($,, [quote(iolist_to_binary(F)) || F <- Row]), $\n]
                      || Row <- Rows]).

quote(F) ->
    case binary:match(F, [<<",">>, <<"\"">>, <<"\n">>, <<"\r">>]) of
        nomatch when F =/= <<>> ->
            case binary:first(F) =:= $\s orelse binary:last(F) =:= $\s of
                true -> [$", F, $"];
                false -> F
            end;
        nomatch -> F;
        _ -> [$", binary:replace(F, <<"\"">>, <<"\"\"">>, [global]), $"]
    end.

%% @doc Build a sheet from CSV text. Each field is a cell input, so
%% formulas (`=A1*2') work; empty fields leave the cell blank.
-spec load(iodata()) -> {ok, cell_sheet:sheet()} | {error, term()}.
load(Data) ->
    case parse(Data) of
        {ok, Rows} ->
            Edits = [{{C, R}, F}
                     || {R, Row} <- enumerate(Rows),
                        {C, F} <- enumerate(Row), F =/= <<>>],
            case cell_sheet:set_many(cell_sheet:new(), Edits) of
                {ok, Sheet, _} -> {ok, Sheet};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

-spec load_file(file:filename()) -> {ok, cell_sheet:sheet()} | {error, term()}.
load_file(Path) ->
    case file:read_file(Path) of
        {ok, Data} -> load(Data);
        {error, Reason} -> {error, {file, Path, Reason}}
    end.

%% @doc The used area as CSV of displayed values.
-spec export_values(cell_sheet:sheet()) -> binary().
export_values(Sheet) -> encode(grid(Sheet, fun cell_sheet:display/2)).

%% @doc The used area as CSV of raw inputs, so it loads back identically.
-spec export_inputs(cell_sheet:sheet()) -> binary().
export_inputs(Sheet) -> encode(grid(Sheet, fun cell_sheet:input/2)).

grid(Sheet, Fun) ->
    {MC, MR} = cell_sheet:bounds(Sheet),
    [[Fun(Sheet, {C, R}) || C <- lists:seq(1, MC)] || R <- lists:seq(1, MR)].

enumerate(L) -> lists:zip(lists:seq(1, length(L)), L).
