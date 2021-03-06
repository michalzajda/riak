%% -------------------------------------------------------------------
%%
%% riak_handoff_sender: send a partition's data via TCP-based handoff
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc send a partition's data via TCP-based handoff

-module(riak_core_handoff_sender).
-export([start_link/3]).
-include_lib("riak_core/include/riak_core_vnode.hrl").
-include_lib("riak_core/include/riak_core_handoff.hrl").
-define(ACK_COUNT, 1000).

start_link(TargetNode, Module, Partition) ->
    Self = self(),
    Pid = spawn_link(fun()->start_fold(TargetNode, Module,Partition, Self) end),
    {ok, Pid}.

start_fold(TargetNode, Module, Partition, ParentPid) ->
    error_logger:info_msg("Starting handoff of partition ~p to ~p~n", 
                          [Partition, TargetNode]),
    [_Name,Host] = string:tokens(atom_to_list(TargetNode), "@"),
    {ok, Port} = get_handoff_port(TargetNode),
    {ok, Socket} = gen_tcp:connect(Host, Port, 
                                   [binary, 
                                    {packet, 4}, 
                                    {header,1}, 
                                    {active, once}], 15000),
    VMaster = list_to_atom(atom_to_list(Module) ++ "_master"),
    ModBin = atom_to_binary(Module, utf8),
    Msg = <<?PT_MSG_OLDSYNC:8,ModBin/binary>>,
    inet:setopts(Socket, [{active, false}]),
    gen_tcp:send(Socket, Msg),
    {ok,[?PT_MSG_OLDSYNC|<<"sync">>]} = gen_tcp:recv(Socket, 0),
    inet:setopts(Socket, [{active, once}]),
    M = <<?PT_MSG_INIT:8,Partition:160/integer>>,
    ok = gen_tcp:send(Socket, M),
    riak_core_vnode_master:sync_command({Partition, node()},
                                        ?FOLD_REQ{
                                           foldfun=fun folder/3,
                                           acc0={Socket,ParentPid,Module,[]}},
                                        VMaster),
    error_logger:info_msg("Handoff of partition ~p to ~p completed~n", 
                          [Partition, TargetNode]),
    gen_fsm:send_event(ParentPid, handoff_complete).

folder(K, V, {Socket, ParentPid, Module, []}) ->
    gen_tcp:controlling_process(Socket, self()),
    visit_item(K, V, {Socket, ParentPid, Module, 0});
folder(K, V, AccIn) ->
    visit_item(K, V, AccIn).

visit_item(K, V, {Socket, ParentPid, Module, ?ACK_COUNT}) ->
    M = <<?PT_MSG_OLDSYNC:8,"sync">>,
    ok = gen_tcp:send(Socket, M),
    inet:setopts(Socket, [{active, false}]),
    {ok,[?PT_MSG_OLDSYNC|<<"sync">>]} = gen_tcp:recv(Socket, 0),
    inet:setopts(Socket, [{active, once}]),
    visit_item(K, V, {Socket, ParentPid, Module, 0});
visit_item(K, V, {Socket, ParentPid, Module, Acc}) ->
    BinObj = Module:encode_handoff_item(K, V),
    M = <<?PT_MSG_OBJ:8,BinObj/binary>>,
    ok = gen_tcp:send(Socket, M),
    {Socket, ParentPid, Module, Acc+1}.
    

get_handoff_port(Node) when is_atom(Node) ->
    case catch(gen_server2:call({riak_core_handoff_listener, Node}, handoff_port)) of
        {'EXIT', _}  ->
            gen_server2:call({riak_kv_handoff_listener, Node}, handoff_port);
        Other -> Other
    end.








