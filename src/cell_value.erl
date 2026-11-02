%% @doc Cell values, coercions and display formatting.
%%
%% A value is one of:
%% <ul>
%%   <li>a float (all numbers are IEEE doubles, as in a spreadsheet),</li>
%%   <li>a binary (text),</li>
%%   <li>`true' or `false',</li>
%%   <li>`empty' (a blank cell),</li>
%%   <li>`{error, Kind}' where Kind is one of `div0', `value', `ref',
%%       `name', `na', `num' or `cycle'.</li>
%% </ul>
-module(cell_value).

-export([parse_number/1, parse_literal/1, display/1, format_number/1,
         error_to_string/1, error_from_string/1,
         to_number/1, to_text/1, to_bool/1, compare/2, is_error/1]).

-export_type([value/0, error_kind/0]).

-type error_kind() :: div0 | value | ref | name | na | num | cycle.
-type value() :: float() | binary() | boolean() | empty | {error, error_kind()}.

%% @doc Parse a decimal number such as `"12"', `"-1.5"', `".5"' or `"2e10"'.
-spec parse_number(string() | binary()) -> {ok, float()} | error.
parse_number(B) when is_binary(B) -> parse_number(unicode:characters_to_list(B));
parse_number(S0) ->
    S = string:trim(S0),
    case re:run(S, "^([+-]?)([0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE]([+-]?[0-9]+))?$",
                [{capture, all_but_first, list}]) of
        {match, [Sign, Mant | ExpPart]} ->
            Mant1 = case Mant of
                        [$. | _] -> [$0 | Mant];
                        _ -> Mant
                    end,
            Mant2 = case lists:member($., Mant1) of
                        false -> Mant1 ++ ".0";
                        true ->
                            case lists:last(Mant1) of
                                $. -> Mant1 ++ "0";
                                _ -> Mant1
                            end
                    end,
            Exp = case ExpPart of
                      [] -> "";
                      [""] -> "";
                      [E] -> "e" ++ E
                  end,
            try list_to_float(Sign ++ Mant2 ++ Exp) of
                F -> {ok, F}
            catch
                error:badarg -> error
            end;
        nomatch ->
            error
    end.

%% @doc Interpret what a user typed into a non-formula cell.
%% Numbers and TRUE/FALSE are recognised; a leading apostrophe forces text.
-spec parse_literal(binary()) -> value().
parse_literal(<<$', Rest/binary>>) -> Rest;
parse_literal(Bin) ->
    case parse_number(Bin) of
        {ok, F} -> F;
        error ->
            case string:uppercase(string:trim(Bin)) of
                <<"TRUE">> -> true;
                <<"FALSE">> -> false;
                _ -> Bin
            end
    end.

-spec display(value()) -> binary().
display(F) when is_float(F) -> format_number(F);
display(B) when is_binary(B) -> B;
display(true) -> <<"TRUE">>;
display(false) -> <<"FALSE">>;
display(empty) -> <<>>;
display({error, K}) -> list_to_binary(error_to_string(K)).

%% @doc Format a number the way a spreadsheet's General format does:
%% integers without a decimal point, other values rounded to 15
%% significant digits (so 0.1 + 0.2 shows as 0.3).
-spec format_number(float()) -> binary().
format_number(F) when F == 0 -> <<"0">>;
format_number(F) ->
    Rounded = list_to_float(lists:flatten(io_lib:format("~.15e", [F]))),
    case Rounded == trunc(Rounded) andalso abs(Rounded) < 1.0e15 of
        true -> integer_to_binary(trunc(Rounded));
        false -> float_to_binary(Rounded, [short])
    end.

-spec error_to_string(error_kind()) -> string().
error_to_string(div0) -> "#DIV/0!";
error_to_string(value) -> "#VALUE!";
error_to_string(ref) -> "#REF!";
error_to_string(name) -> "#NAME?";
error_to_string(na) -> "#N/A";
error_to_string(num) -> "#NUM!";
error_to_string(cycle) -> "#CYCLE!".

-spec error_from_string(string()) -> error_kind().
error_from_string("#DIV/0!") -> div0;
error_from_string("#VALUE!") -> value;
error_from_string("#REF!") -> ref;
error_from_string("#NAME?") -> name;
error_from_string("#N/A") -> na;
error_from_string("#NUM!") -> num;
error_from_string("#CYCLE!") -> cycle.

-spec is_error(value()) -> boolean().
is_error({error, _}) -> true;
is_error(_) -> false.

%% @doc Coerce for arithmetic. Text that looks like a number converts;
%% other text is a `#VALUE!' error.
-spec to_number(value()) -> {ok, float()} | {error, error_kind()}.
to_number(F) when is_float(F) -> {ok, F};
to_number(true) -> {ok, 1.0};
to_number(false) -> {ok, 0.0};
to_number(empty) -> {ok, 0.0};
to_number({error, _} = E) -> E;
to_number(B) when is_binary(B) ->
    case parse_number(B) of
        {ok, F} -> {ok, F};
        error -> {error, value}
    end.

-spec to_text(value()) -> {ok, binary()} | {error, error_kind()}.
to_text({error, _} = E) -> E;
to_text(V) -> {ok, display(V)}.

-spec to_bool(value()) -> {ok, boolean()} | {error, error_kind()}.
to_bool(B) when is_boolean(B) -> {ok, B};
to_bool(F) when is_float(F) -> {ok, F /= 0};
to_bool(empty) -> {ok, false};
to_bool({error, _} = E) -> E;
to_bool(T) when is_binary(T) ->
    case string:uppercase(string:trim(T)) of
        <<"TRUE">> -> {ok, true};
        <<"FALSE">> -> {ok, false};
        _ -> {error, value}
    end.

%% @doc Total order used by comparison operators: numbers sort before
%% text, text before booleans; text compares case-insensitively and a
%% blank cell acts as the zero value of whatever it is compared with.
-spec compare(value(), value()) -> lt | eq | gt.
compare(empty, empty) -> eq;
compare(empty, B) -> compare(zero_like(B), B);
compare(A, empty) -> compare(A, zero_like(A));
compare(A, B) ->
    case {rank(A), rank(B)} of
        {R, R} -> cmp(key(A), key(B));
        {RA, RB} -> cmp(RA, RB)
    end.

zero_like(F) when is_float(F) -> 0.0;
zero_like(B) when is_binary(B) -> <<>>;
zero_like(B) when is_boolean(B) -> false.

rank(F) when is_float(F) -> 1;
rank(B) when is_binary(B) -> 2;
rank(B) when is_boolean(B) -> 3.

key(B) when is_binary(B) -> string:casefold(B);
key(V) -> V.

cmp(A, B) when A < B -> lt;
cmp(A, B) when A > B -> gt;
cmp(_, _) -> eq.
