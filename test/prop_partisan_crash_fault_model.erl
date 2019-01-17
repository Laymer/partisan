%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Christopher S. Meiklejohn.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(prop_partisan_crash_fault_model).

-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-include_lib("proper/include/proper.hrl").

-compile([export_all]).

-define(NUM_NODES, 3).
-define(MANAGER, partisan_pluggable_peer_service_manager).

%%%===================================================================
%%% Generators
%%%===================================================================

message() ->
    ?LET(Id, erlang:unique_integer([positive, monotonic]), 
        ?LET(Random, integer(),
            {Id, Random})).

node_name() ->
    ?LET(Names, names(), oneof(Names)).

names() ->
    NameFun = fun(N) -> 
        list_to_atom("node_" ++ integer_to_list(N)) 
    end,
    lists:map(NameFun, lists:seq(1, ?NUM_NODES)).

%%%===================================================================
%%% Fault Functions
%%%===================================================================

-record(fault_model_state, {active_faults,
                            crashed_nodes,
                            send_omissions}).

fault_commands() ->
    [
     %% Simulate crash failures.
     {call, ?MODULE, crash, [node_name()]},

     %% Send omission failures.
     {call, ?MODULE, begin_send_omission, [node_name(), node_name()]}
    ].

%% Names of the node functions so we kow when we can dispatch to the node
%% pre- and postconditions.
fault_functions() ->
    lists:map(fun({call, _Mod, Fun, _Args}) -> Fun end, fault_commands()).

fault_initial_state() ->
    ActiveFaults = 0,
    CrashedNodes = [],
    SendOmissions = dict:new(),
    #fault_model_state{active_faults=ActiveFaults, 
                       crashed_nodes=CrashedNodes, 
                       send_omissions=SendOmissions}.

%% Send omission.
fault_precondition(#fault_model_state{crashed_nodes=CrashedNodes}=FaultModelState, {call, _Mod, begin_send_omission, [SourceNode, DestinationNode]}=Call) ->
    %% Fault must be allowed at this moment.
    fault_allowed(Call, FaultModelState) andalso 

    %% Nodes must not be the same node.
    SourceNode =/= DestinationNode andalso

    %% Both nodes have to be non-crashed.
    not lists:member(SourceNode, CrashedNodes) andalso not lists:member(DestinationNode, CrashedNodes);

%% Crash failures.
fault_precondition(#fault_model_state{crashed_nodes=CrashedNodes}=FaultModelState, {call, _Mod, crash, [Node]}=Call) ->
    %% Fault must be allowed at this moment.
    fault_allowed(Call, FaultModelState) andalso 

    %% Node to crash must be online at the time.
    not lists:member(Node, CrashedNodes);

fault_precondition(_FaultModelState, {call, Mod, Fun, [_Node|_]=Args}) ->
    fault_debug("fault precondition fired for ~p:~p(~p)", [Mod, Fun, Args]),
    false.

%% Send omission.
fault_next_state(#fault_model_state{active_faults=ActiveFaults, send_omissions=SendOmissions0} = FaultModelState, _Res, {call, _Mod, begin_send_omission, [SourceNode, DestinationNode]}) ->
    SendOmissions = dict:store({SourceNode, DestinationNode}, true, SendOmissions0),
    FaultModelState#fault_model_state{active_faults=ActiveFaults + 1, send_omissions=SendOmissions};

%% Crashing a node adds a node to the crashed state.
fault_next_state(#fault_model_state{active_faults=ActiveFaults, crashed_nodes=CrashedNodes} = FaultModelState, _Res, {call, _Mod, crash, [Node]}) ->
    FaultModelState#fault_model_state{active_faults=ActiveFaults + 1, crashed_nodes=CrashedNodes ++ [Node]};

fault_next_state(FaultModelState, _Res, _Call) ->
    FaultModelState.

%% Send omission.
fault_postcondition(_FaultModelState, {call, _Mod, begin_send_omission, [_SourceNode, _DestinationNode]}, ok) ->
    true;

%% Crashes are allowed.
fault_postcondition(_FaultModelState, {call, _Mod, crash, [_Node]}, ok) ->
    true;

fault_postcondition(_FaultModelState, {call, Mod, Fun, [_Node|_]=Args}, Res) ->
    fault_debug("fault postcondition fired for ~p:~p(~p) with response ~p", [Mod, Fun, Args, Res]),
    false.

%%%===================================================================
%%% Helper Functions
%%%===================================================================

-define(FAULT_DEBUG, true).

-define(ETS, prop_partisan).
-define(NAME, fun(Name) -> [{_, NodeName}] = ets:lookup(?ETS, Name), NodeName end).

%% Is crashed?
fault_is_crashed(#fault_model_state{crashed_nodes=CrashedNodes}, Name) ->
    lists:member(Name, CrashedNodes).

%% Is this fault allowed?
fault_allowed({call, _Mod, begin_send_omission, _Args}, #fault_model_state{active_faults=ActiveFaults}) ->
    Tolerance = ?NUM_NODES - 1,       %% Assumed N+1 fault-tolerance.
    ActiveFaults =< Tolerance;        %% We can tolerate another failure.

fault_allowed({call, _Mod, crash, [Node]}, #fault_model_state{active_faults=ActiveFaults, crashed_nodes=CrashedNodes}) ->
    Tolerance = ?NUM_NODES - 1,       %% Assumed N+1 fault-tolerance.
    ActiveFaults =< Tolerance orelse  %% We can tolerate another failure.

    %% or, a send omission can be turned into a crash.
    (ActiveFaults =:= Tolerance andalso lists:member(Node, CrashedNodes)).

%% Should we do node debugging?
fault_debug(Line, Args) ->
    case ?FAULT_DEBUG of
        true ->
            lager:info("~p: " ++ Line, [?MODULE] ++ Args);
        false ->
            ok
    end.

%% Crash the node.
%% Crash is a stop that doesn't wait for all members to know about the crash.
crash(Name) ->
    fault_debug("crashing node: ~p", [Name]),

    case ct_slave:stop(Name) of
        {ok, _} ->
            ok;
        {error, stop_timeout, _} ->
            fault_debug("Failed to stop node ~p: stop_timeout!", [Name]),
            crash(Name),
            ok;
        {error, not_started, _} ->
            ok;
        Error ->
            ct:fail(Error)
    end.

%% Create a send omission failure.
begin_send_omission(SourceNode, DestinationNode0) ->
    fault_debug("begin_send_omission: source_node ~p destination_node ~p", [SourceNode, DestinationNode0]),

    %% Convert to real node name and not symbolic name.
    DestinationNode = ?NAME(DestinationNode0),

    InterpositionFun = fun({forward_message, N, Message}) ->
        case N of
            DestinationNode ->
                lager:info("~p: dropping packet from ~p to ~p due to interposition.", [node(), SourceNode, DestinationNode]),
                undefined;
            OtherNode ->
                lager:info("~p: allowing message, doesn't match interposition as destination is ~p and not ~p", [node(), OtherNode, DestinationNode]),
                Message
        end;
        ({receive_message, _N, Message}) -> Message
    end,
    rpc:call(?NAME(SourceNode), ?MANAGER, add_interposition_fun, [{send_omission, DestinationNode}, InterpositionFun]).