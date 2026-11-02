%% @doc Formula ASTs: parsing, printing, dependency extraction and
%% relative-reference shifting (what happens when a formula is copied).
%%
%% AST nodes:
%% <ul>
%%   <li>`{num, float()}', `{str, binary()}', `{bool, boolean()}',
%%       `{err, error_kind()}'</li>
%%   <li>`{ref, Col, Row, AbsCol, AbsRow}' and `{range, Ref, Ref}'</li>
%%   <li>`{binop, Op, Left, Right}', `{neg, E}', `{pct, E}'</li>
%%   <li>`{call, Name :: binary(), Args}' and `{name, binary()}' (an
%%       identifier that is not a known name; evaluates to `#NAME?')</li>
%% </ul>
-module(cell_formula).

-export([parse/1, to_string/1, refs/1, shift/3]).
%% Used by the generated parser.
-export([mk_ref/1, mk_range/2, mk_ident/1]).

-export_type([ast/0]).

-type ref() :: {ref, pos_integer(), pos_integer(), boolean(), boolean()}.
-type ast() :: {num, float()} | {str, binary()} | {bool, boolean()}
             | {err, cell_value:error_kind()}
             | ref() | {range, ref(), ref()}
             | {binop, atom(), ast(), ast()} | {neg, ast()} | {pct, ast()}
             | {call, binary(), [ast()]} | {name, binary()}.

%% @doc Parse formula source (without the leading `=').
-spec parse(string() | binary()) -> {ok, ast()} | {error, string()}.
parse(Src) ->
    case cell_lexer:string(unicode:characters_to_list(Src)) of
        {ok, [], _} ->
            {error, "empty formula"};
        {ok, Tokens, _} ->
            case cell_parser:parse(Tokens) of
                {ok, Ast} -> {ok, Ast};
                {error, {_, Mod, Msg}} -> {error, syntax_message(Mod:format_error(Msg))}
            end;
        {error, {_, Mod, Info}, _} ->
            {error, lists:flatten(Mod:format_error(Info))}
    end.

syntax_message(Msg) ->
    case lists:flatten(Msg) of
        "syntax error before: " -> "unexpected end of formula";
        Flat -> Flat
    end.

-spec mk_ref(string()) -> ast().
mk_ref(Chars) ->
    case cell_ref:parse_ref(Chars) of
        {ok, {C, R, AC, AR}} -> {ref, C, R, AC, AR};
        error -> {name, unicode:characters_to_binary(string:uppercase(Chars))}
    end.

-spec mk_range(string(), string()) -> ast().
mk_range(A, B) ->
    case {mk_ref(A), mk_ref(B)} of
        {{ref, _, _, _, _} = RA, {ref, _, _, _, _} = RB} -> {range, RA, RB};
        _ -> {name, unicode:characters_to_binary(string:uppercase(A ++ ":" ++ B))}
    end.

-spec mk_ident(string()) -> ast().
mk_ident("TRUE") -> {bool, true};
mk_ident("FALSE") -> {bool, false};
mk_ident(Name) -> {name, unicode:characters_to_binary(Name)}.

%%% Printing ---------------------------------------------------------------

%% @doc Print an AST back to formula source with minimal parentheses.
%% `parse(to_string(Ast))' gives back `Ast'.
-spec to_string(ast()) -> binary().
to_string(Ast) -> iolist_to_binary(pp(Ast)).

prec({binop, Op, _, _}) -> op_prec(Op);
prec({neg, _}) -> 6;
prec({pct, _}) -> 7;
prec(_) -> 8.

op_prec(Op) when Op =:= '='; Op =:= '<>'; Op =:= '<'; Op =:= '>';
                 Op =:= '<='; Op =:= '>=' -> 1;
op_prec('&') -> 2;
op_prec(Op) when Op =:= '+'; Op =:= '-' -> 3;
op_prec(Op) when Op =:= '*'; Op =:= '/' -> 4;
op_prec('^') -> 5.

pp({num, F}) when F == trunc(F), abs(F) < 1.0e15 -> integer_to_list(trunc(F));
pp({num, F}) -> float_to_list(F, [short]);
pp({str, S}) -> [$", string:replace(S, "\"", "\"\"", all), $"];
pp({bool, true}) -> "TRUE";
pp({bool, false}) -> "FALSE";
pp({err, K}) -> cell_value:error_to_string(K);
pp({ref, C, R, AC, AR}) -> cell_ref:to_string({C, R}, {AC, AR});
pp({range, A, B}) -> [pp(A), $:, pp(B)];
pp({name, N}) -> N;
pp({call, Name, Args}) -> [Name, $(, lists:join($,, [pp(A) || A <- Args]), $)];
pp({neg, E}) -> [$-, wrap(E, prec(E) < 6)];
pp({pct, E}) -> [wrap(E, prec(E) < 7), $%];
pp({binop, Op, L, R} = Node) ->
    P = prec(Node),
    [wrap(L, prec(L) < P), atom_to_list(Op), wrap(R, prec(R) =< P)].

wrap(E, true) -> [$(, pp(E), $)];
wrap(E, false) -> pp(E).

%%% Dependencies -----------------------------------------------------------

%% @doc Every cell position the formula reads, ranges expanded, sorted
%% and without duplicates.
-spec refs(ast()) -> [cell_ref:pos()].
refs(Ast) -> lists:usort(refs(Ast, [])).

refs({ref, C, R, _, _}, Acc) -> [{C, R} | Acc];
refs({range, {ref, C1, R1, _, _}, {ref, C2, R2, _, _}}, Acc) ->
    {{CA, RA}, {CB, RB}} = cell_ref:normalize_range({C1, R1}, {C2, R2}),
    [{C, R} || C <- lists:seq(CA, CB), R <- lists:seq(RA, RB)] ++ Acc;
refs({binop, _, L, R}, Acc) -> refs(R, refs(L, Acc));
refs({neg, E}, Acc) -> refs(E, Acc);
refs({pct, E}, Acc) -> refs(E, Acc);
refs({call, _, Args}, Acc) -> lists:foldl(fun refs/2, Acc, Args);
refs(_, Acc) -> Acc.

%%% Shifting ---------------------------------------------------------------

%% @doc Move relative references by `DCol' columns and `DRow' rows, as
%% when a formula is copied from one cell to another. Absolute (`$')
%% parts stay put. A reference pushed off the grid becomes `#REF!'.
-spec shift(ast(), integer(), integer()) -> ast().
shift({ref, C, R, AC, AR}, DC, DR) ->
    C1 = case AC of true -> C; false -> C + DC end,
    R1 = case AR of true -> R; false -> R + DR end,
    case cell_ref:valid({C1, R1}) of
        true -> {ref, C1, R1, AC, AR};
        false -> {err, ref}
    end;
shift({range, A, B}, DC, DR) ->
    case {shift(A, DC, DR), shift(B, DC, DR)} of
        {{ref, _, _, _, _} = A1, {ref, _, _, _, _} = B1} -> {range, A1, B1};
        _ -> {err, ref}
    end;
shift({binop, Op, L, R}, DC, DR) -> {binop, Op, shift(L, DC, DR), shift(R, DC, DR)};
shift({neg, E}, DC, DR) -> {neg, shift(E, DC, DR)};
shift({pct, E}, DC, DR) -> {pct, shift(E, DC, DR)};
shift({call, N, Args}, DC, DR) -> {call, N, [shift(A, DC, DR) || A <- Args]};
shift(Other, _, _) -> Other.
