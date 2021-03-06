%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_router_helper).

-behaviour(gen_server).

-include("emqx.hrl").

%% Mnesia bootstrap
-export([mnesia/1]).

-boot_mnesia({mnesia, [boot]}).
-copy_mnesia({mnesia, [copy]}).

%% API
-export([start_link/0, monitor/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% internal export
-export([stats_fun/0]).

-record(routing_node, {name, const = unused}).
-record(state, {nodes = []}).

-compile({no_auto_import, [monitor/1]}).

-define(SERVER, ?MODULE).
-define(ROUTE, emqx_route).
-define(ROUTING_NODE, emqx_routing_node).
-define(LOCK, {?MODULE, cleanup_routes}).

%%------------------------------------------------------------------------------
%% Mnesia bootstrap
%%------------------------------------------------------------------------------

mnesia(boot) ->
    ok = ekka_mnesia:create_table(?ROUTING_NODE, [
                {type, set},
                {ram_copies, [node()]},
                {record_name, routing_node},
                {attributes, record_info(fields, routing_node)},
                {storage_properties, [{ets, [{read_concurrency, true}]}]}]);

mnesia(copy) ->
    ok = ekka_mnesia:copy_table(?ROUTING_NODE).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Starts the router helper
-spec(start_link() -> {ok, pid()} | ignore | {error, any()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Monitor routing node
-spec(monitor(node() | {binary(), node()}) -> ok).
monitor({_Group, Node}) ->
    monitor(Node);
monitor(Node) when is_atom(Node) ->
    case ekka:is_member(Node)
         orelse ets:member(?ROUTING_NODE, Node) of
        true  -> ok;
        false -> mnesia:dirty_write(?ROUTING_NODE, #routing_node{name = Node})
    end.

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([]) ->
    _ = ekka:monitor(membership),
    _ = mnesia:subscribe({table, ?ROUTING_NODE, simple}),
    Nodes = lists:foldl(
              fun(Node, Acc) ->
                  case ekka:is_member(Node) of
                      true  -> Acc;
                      false -> _ = erlang:monitor_node(Node, true),
                               [Node | Acc]
                  end
              end, [], mnesia:dirty_all_keys(?ROUTING_NODE)),
    emqx_stats:update_interval(route_stats, fun ?MODULE:stats_fun/0),
    {ok, #state{nodes = Nodes}, hibernate}.

handle_call(Req, _From, State) ->
    emqx_logger:error("[RouterHelper] unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    emqx_logger:error("[RouterHelper] unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({mnesia_table_event, {write, #routing_node{name = Node}, _}}, State = #state{nodes = Nodes}) ->
    emqx_logger:info("[RouterHelper] write routing node: ~s", [Node]),
    case ekka:is_member(Node) orelse lists:member(Node, Nodes) of
        true  -> {noreply, State};
        false -> _ = erlang:monitor_node(Node, true),
                 {noreply, State#state{nodes = [Node | Nodes]}}
    end;

handle_info({mnesia_table_event, _Event}, State) ->
    {noreply, State};

handle_info({nodedown, Node}, State = #state{nodes = Nodes}) ->
    global:trans({?LOCK, self()},
                 fun() ->
                     mnesia:transaction(fun cleanup_routes/1, [Node])
                 end),
    mnesia:dirty_delete(?ROUTING_NODE, Node),
    {noreply, State#state{nodes = lists:delete(Node, Nodes)}, hibernate};

handle_info({membership, {mnesia, down, Node}}, State) ->
    handle_info({nodedown, Node}, State);

handle_info({membership, _Event}, State) ->
    {noreply, State};

handle_info(Info, State) ->
    emqx_logger:error("[RouteHelper] unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{}) ->
    ekka:unmonitor(membership),
    emqx_stats:cancel_update(route_stats),
    mnesia:unsubscribe({table, ?ROUTING_NODE, simple}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

stats_fun() ->
    case ets:info(?ROUTE, size) of
        undefined -> ok;
        Size ->
            emqx_stats:setstat('routes/count', 'routes/max', Size),
            emqx_stats:setstat('topics/count', 'topics/max', Size)
    end.

cleanup_routes(Node) ->
    Patterns = [#route{_ = '_', dest = Node},
                #route{_ = '_', dest = {'_', Node}}],
    [mnesia:delete_object(?ROUTE, Route, write)
     || Pat <- Patterns, Route <- mnesia:match_object(?ROUTE, Pat, write)].

