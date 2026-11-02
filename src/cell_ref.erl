%% @doc A1-style cell references.
%%
%% A position is `{Col, Row}`, both 1-based, so `"B3"` is `{2, 3}`.
%% Columns run from `A` to `XFD` (16384) and rows from 1 to 1048576,
%% the same grid limits as a modern spreadsheet.
-module(cell_ref).

-export([parse/1, parse_ref/1, to_string/1, to_string/2,
         letters_to_col/1, col_to_letters/1, max_col/0, max_row/0,
         valid/1, normalize_range/2]).

-export_type([pos/0]).

-type pos() :: {pos_integer(), pos_integer()}.

-define(MAX_COL, 16384).
-define(MAX_ROW, 1048576).

-spec max_col() -> pos_integer().
max_col() -> ?MAX_COL.

-spec max_row() -> pos_integer().
max_row() -> ?MAX_ROW.

%% @doc Parse `"B3"` (case-insensitive, `$` markers allowed) into `{2, 3}`.
-spec parse(string() | binary()) -> {ok, pos()} | error.
parse(Ref) when is_binary(Ref) -> parse(unicode:characters_to_list(Ref));
parse(Ref) when is_list(Ref) ->
    case parse_ref(Ref) of
        {ok, {C, R, _, _}} -> {ok, {C, R}};
        error -> error
    end.

%% @doc Parse a reference keeping its absolute markers:
%% `"$B3"` gives `{ok, {2, 3, true, false}}`.
-spec parse_ref(string()) ->
          {ok, {pos_integer(), pos_integer(), boolean(), boolean()}} | error.
parse_ref(Ref) ->
    S0 = string:uppercase(Ref),
    {AbsC, S1} = dollar(S0),
    {Letters, S2} = lists:splitwith(fun(Ch) -> Ch >= $A andalso Ch =< $Z end, S1),
    {AbsR, S3} = dollar(S2),
    {Digits, Rest} = lists:splitwith(fun(Ch) -> Ch >= $0 andalso Ch =< $9 end, S3),
    case {Letters, Digits, Rest} of
        {[_ | _], [D | _], []} when length(Letters) =< 3, D =/= $0 ->
            C = letters_to_col(Letters),
            R = list_to_integer(Digits),
            case valid({C, R}) of
                true -> {ok, {C, R, AbsC, AbsR}};
                false -> error
            end;
        _ ->
            error
    end.

dollar([$$ | Rest]) -> {true, Rest};
dollar(S) -> {false, S}.

-spec valid(term()) -> boolean().
valid({C, R}) when is_integer(C), is_integer(R) ->
    C >= 1 andalso C =< ?MAX_COL andalso R >= 1 andalso R =< ?MAX_ROW;
valid(_) -> false.

-spec to_string(pos()) -> string().
to_string(Pos) -> to_string(Pos, {false, false}).

-spec to_string(pos(), {boolean(), boolean()}) -> string().
to_string({C, R}, {AbsC, AbsR}) ->
    mark(AbsC) ++ col_to_letters(C) ++ mark(AbsR) ++ integer_to_list(R).

mark(true) -> "$";
mark(false) -> "".

%% @doc `"A"` is 1, `"Z"` is 26, `"AA"` is 27.
-spec letters_to_col(string()) -> pos_integer().
letters_to_col(Letters) ->
    lists:foldl(fun(Ch, Acc) -> Acc * 26 + (Ch - $A + 1) end, 0,
                string:uppercase(Letters)).

-spec col_to_letters(pos_integer()) -> string().
col_to_letters(N) when is_integer(N), N >= 1 -> col_to_letters(N, []).

col_to_letters(0, Acc) -> Acc;
col_to_letters(N, Acc) ->
    M = N - 1,
    col_to_letters(M div 26, [$A + M rem 26 | Acc]).

%% @doc Order two corners into `{TopLeft, BottomRight}`.
-spec normalize_range(pos(), pos()) -> {pos(), pos()}.
normalize_range({C1, R1}, {C2, R2}) ->
    {{min(C1, C2), min(R1, R2)}, {max(C1, C2), max(R1, R2)}}.
