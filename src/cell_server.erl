%% @doc A live spreadsheet process. Holds a `cell_sheet' and pushes value
%% changes to subscribed processes as
%% `{cellwork, ServerPid, [{Pos, Value}]}' messages. Subscribers are
%% monitored and dropped automatically when they exit.
-module(cell_server).
-behaviour(gen_server).

-export([start_link/0, start_link/1, stop/1,
         set/3, set_many/2, clear/2, get/2, display/2, input/2,
         snapshot/1, subscribe/1, unsubscribe/1, subscribers/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {sheet :: cell_sheet:sheet(),
                subs = #{} :: #{pid() => reference()}}).

-spec start_link() -> {ok, pid()}.
start_link() -> start_link(cell_sheet:new()).

%% @doc Start a server around an existing sheet.
-spec start_link(cell_sheet:sheet()) -> {ok, pid()}.
start_link(Sheet) -> gen_server:start_link(?MODULE, Sheet, []).

-spec stop(pid()) -> ok.
stop(Server) -> gen_server:stop(Server).

-spec set(pid(), cell_sheet:ref(), iodata()) ->
          {ok, [cell_sheet:change()]} | {error, term()}.
set(Server, Ref, Input) -> set_many(Server, [{Ref, Input}]).

%% @doc Atomic batch edit; subscribers get one notification per batch.
-spec set_many(pid(), [{cell_sheet:ref(), iodata()}]) ->
          {ok, [cell_sheet:change()]} | {error, term()}.
set_many(Server, Edits) -> gen_server:call(Server, {set_many, Edits}).

-spec clear(pid(), cell_sheet:ref()) -> {ok, [cell_sheet:change()]} | {error, term()}.
clear(Server, Ref) -> set(Server, Ref, <<>>).

-spec get(pid(), cell_sheet:ref()) -> cell_value:value().
get(Server, Ref) -> gen_server:call(Server, {read, get, Ref}).

-spec display(pid(), cell_sheet:ref()) -> binary().
display(Server, Ref) -> gen_server:call(Server, {read, display, Ref}).

-spec input(pid(), cell_sheet:ref()) -> binary().
input(Server, Ref) -> gen_server:call(Server, {read, input, Ref}).

%% @doc The current sheet as an immutable value.
-spec snapshot(pid()) -> cell_sheet:sheet().
snapshot(Server) -> gen_server:call(Server, snapshot).

%% @doc Subscribe the calling process to change notifications.
-spec subscribe(pid()) -> ok.
subscribe(Server) -> gen_server:call(Server, {subscribe, self()}).

-spec unsubscribe(pid()) -> ok.
unsubscribe(Server) -> gen_server:call(Server, {unsubscribe, self()}).

-spec subscribers(pid()) -> [pid()].
subscribers(Server) -> gen_server:call(Server, subscribers).

%% gen_server callbacks

init(Sheet) -> {ok, #state{sheet = Sheet}}.

handle_call({set_many, Edits}, _From, State = #state{sheet = Sheet}) ->
    try cell_sheet:set_many(Sheet, Edits) of
        {ok, Sheet1, Changed} ->
            notify(State, Changed),
            {reply, {ok, Changed}, State#state{sheet = Sheet1}};
        {error, _} = Err ->
            {reply, Err, State}
    catch
        error:Reason -> {reply, {error, {badarg, Reason}}, State}
    end;
handle_call({read, Fun, Ref}, _From, State = #state{sheet = Sheet}) ->
    Reply = try {ok, cell_sheet:Fun(Sheet, Ref)}
            catch error:_ -> {error, {bad_ref, Ref}}
            end,
    case Reply of
        {ok, V} -> {reply, V, State};
        Err -> {reply, Err, State}
    end;
handle_call(snapshot, _From, State) ->
    {reply, State#state.sheet, State};
handle_call({subscribe, Pid}, _From, State = #state{subs = Subs}) ->
    case Subs of
        #{Pid := _} -> {reply, ok, State};
        _ ->
            MRef = erlang:monitor(process, Pid),
            {reply, ok, State#state{subs = Subs#{Pid => MRef}}}
    end;
handle_call({unsubscribe, Pid}, _From, State = #state{subs = Subs}) ->
    case maps:take(Pid, Subs) of
        {MRef, Subs1} ->
            erlang:demonitor(MRef, [flush]),
            {reply, ok, State#state{subs = Subs1}};
        error ->
            {reply, ok, State}
    end;
handle_call(subscribers, _From, State = #state{subs = Subs}) ->
    {reply, lists:sort(maps:keys(Subs)), State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'DOWN', MRef, process, Pid, _}, State = #state{subs = Subs}) ->
    case Subs of
        #{Pid := MRef} -> {noreply, State#state{subs = maps:remove(Pid, Subs)}};
        _ -> {noreply, State}
    end;
handle_info(_Msg, State) -> {noreply, State}.

notify(_State, []) -> ok;
notify(#state{subs = Subs}, Changed) ->
    Msg = {cellwork, self(), Changed},
    _ = [Pid ! Msg || Pid <- maps:keys(Subs)],
    ok.
