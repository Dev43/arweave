-module(ar_bridge).
-export([start/0, start/1, start/2, start/3]).
-export([add_tx/2, add_block/4, add_block/6]). % Called from ar_http_iface
-export([add_remote_peer/2, add_local_peer/2]).
-export([get_remote_peers/1, set_remote_peers/2]).
-export([start_link/1]).
-export([ignore_id/1]).
-export([ignore_peer/2]).
-export([is_id_ignored/1]).
-include("ar.hrl").

%%% Represents a bridge node in the internal gossip network
%%% to the external message passing interfaces.

%% Internal state definition.
-record(state, {
	protocol = http, % Interface to bridge across
	gossip, % Gossip state
	external_peers, % Peers to send message to.
	processed = [], % IDs to ignore.
	firewall = ar_firewall:start(),
	port,
	ignored_peers = []
}).

%% @doc Start a node, linking to a supervisor process
start_link(Args) ->
	PID = erlang:apply(ar_bridge, start, Args),
	{ok, PID}.

%% @doc Launch a bridge node.
start() -> start([]).
start(ExtPeers) -> start(ExtPeers, []).
start(ExtPeers, IntPeers) -> start(ExtPeers, IntPeers, ?DEFAULT_HTTP_IFACE_PORT).
start(ExtPeers, IntPeers, Port) ->
	spawn(
		fun() ->
			ar:report([starting_ignored_ids_db]),
			ets:new(ignored_ids, [set, public, named_table]),
			receive stop -> ok end
		end
	),
	receive after 250 -> ok end,
    PID =
		spawn(
			fun() ->
				server(
					#state {
						gossip = ar_gossip:init(IntPeers),
						external_peers = ExtPeers,
						port = Port
					}
				)
			end
		),
	reset_timer(PID, get_more_peers),
	PID.

%% @doc Get a list of remote peers
get_remote_peers(PID) ->
	PID ! {get_peers, remote, self()},
	receive
		{remote_peers, ExternalPeers} ->
			ExternalPeers
	after ?LOCAL_NET_TIMEOUT -> []
	end.

%% @doc Reset the remote peers list to a specific set.
set_remote_peers(PID, Peers) ->
	PID ! {set_peers, Peers}.

%% @doc Notify the bridge of a new external block.
add_block(PID, OriginPeer, Block, RecallBlock) ->
	PID ! {add_block, OriginPeer, Block, RecallBlock}.
add_block(PID, OriginPeer, Block, RecallBlock, Key, Nonce) ->
	PID ! {add_block, OriginPeer, Block, RecallBlock, Key, Nonce}.

%% @doc Notify the bridge of a new external block.
add_tx(PID, TX) ->%, OriginPeer) ->
	PID ! {add_tx, TX}.%, OriginPeer}.

%% @doc Add a remote HTTP peer.
add_remote_peer(PID, Node) ->
	PID ! {add_peer, remote, Node}.

%% @doc Add a local gossip peer.
add_local_peer(PID, Node) ->
	PID ! {add_peer, local, Node}.

%% @doc Ignore messages matching the given ID.
ignore_id(ID) ->
	ets:insert(ignored_ids, {ID, ignored}).

%% @doc Schedule a message timer.
reset_timer(PID, get_more_peers) ->
	erlang:send_after(?GET_MORE_PEERS_TIME, PID, {get_more_peers, PID}).

ignore_peer(_PID, []) -> ok;
ignore_peer(PID, Peer) ->
	PID ! {ignore_peer, Peer}.

is_id_ignored(ID) ->
	case ets:lookup(ignored_ids, ID) of
		[{ID, ignored}] -> true;
		[] -> false
	end.

%%% INTERNAL FUNCTIONS

%% @doc Main server loop.
server(S = #state { gossip = GS0, external_peers = ExtPeers }) ->
	try (receive
		{ignore_peer, Peer} ->
			timer:send_after(?IGNORE_PEERS_TIME, {unignore_peer, Peer}),
			server(S#state { ignored_peers = [Peer|S#state.ignored_peers] });
		{unignore_peer, Peer} ->
			server(S#state { ignored_peers = lists:delete(Peer, S#state.ignored_peers) });
		{add_tx, TX} -> %, _OriginPeer} ->
			server(maybe_send_to_internal(S, tx, TX));
		{add_block, OriginPeer, Block, RecallBlock} ->
			server(maybe_send_to_internal(S, block, {OriginPeer, Block, RecallBlock}));
		{add_block, OriginPeer, Block, RecallBlock, Key, Nonce} ->
			server(maybe_send_to_internal(S, block, {OriginPeer, Block, RecallBlock}, Key, Nonce));
		{add_peer, remote, Peer} ->
			case lists:member(Peer, ?PEER_PERMANENT_BLACKLIST) of
				true -> server(S);
				false -> server(S#state { external_peers = ar_util:unique([Peer|ExtPeers])})
			end;
		{add_peer, local, Peer} ->
			server(S#state { gossip = ar_gossip:add_peers(GS0, Peer)});
		{get_peers, remote, Peer} ->
			Peer ! {remote_peers, S#state.external_peers},
			server(S);
		{set_peers, Peers} ->
			server(S#state { external_peers = Peers });
		{update_peers, remote, Peers} ->
			server(S#state {external_peers = Peers});
		Msg when is_record(Msg, gs_msg) ->
			case ar_gossip:recv(GS0, Msg) of
				{_, ignore} ->
					server(S);
				Gossip ->
					server(do_send_to_external(S, Gossip))
			end;
		{get_more_peers, PID} ->
			spawn(
				fun() ->
					Peers = ar_manage_peers:update(S#state.external_peers),
					lists:map(fun ar_http_iface:add_peer/1, Peers),
					PID ! {update_peers, remote, Peers},
					reset_timer(PID, get_more_peers)
				end
			),
			server(S)
	end)
	catch
		throw:Term ->
			ar:report(
				[
					{'EXCEPTION', {Term}}
				]
			),
			server(S);
		exit:Term ->
			ar:report(
				[
					{'EXIT', Term}
				],
				server(S)
			);
		error:Term ->
			ar:report(
				[
					{'EXIT', {Term, erlang:get_stacktrace()}}
				]
			),
			server(S)
	end.
%% @doc Potentially send a message to internal processes.
maybe_send_to_internal(
		S = #state {
			gossip = GS,
			firewall = FW,
			processed = Procd
		},
		Type,
		Data) ->
	case
		% TODO: Is it always appropriate not to check whether the block has 
		% already been processed?
		% (not already_processed(Procd, Type, Data)) andalso
		ar_firewall:scan(FW, Type, Data)
	of
		false ->
			% If the data does not pass the scan, ignore the message.
			S;
		true ->
			% The message is at least valid, distribute it.
			{NewGS, _} =
				ar_gossip:send(
					GS,
					Msg = case Type of
						tx ->
							{add_tx, Data};
						block ->
							{OriginPeer, NewB, RecallB} = Data,
							{new_block,
								OriginPeer,
								NewB#block.height,
								NewB,
								RecallB
							}
					end),
			send_to_external(S, Msg),
			add_processed(Type, Data, Procd),
			S#state { gossip = NewGS }
	end.
maybe_send_to_internal(
		S = #state {
			gossip = GS,
			firewall = FW,
			processed = Procd
		},
		Type,
		Data,
		Key,
		Nonce) ->
	case
		% TODO: Is it always appropriate not to check whether the block has 
		% already been processed?
		%(not already_processed(Procd, Type, Data)) andalso
		ar_firewall:scan(FW, Type, Data)
	of
		false ->
			% If the data does not pass the scan, ignore the message.
			S;
		true ->
			% The message is at least valid, distribute it.
			{NewGS, _} =
				ar_gossip:send(
					GS,
					Msg = case Type of
						tx ->
							{add_tx, Data};
						block ->
							{OriginPeer, NewB, RecallB} = Data,
							{new_block,
								OriginPeer,
								NewB#block.height,
								NewB,
								RecallB
							}
					end),
			send_to_external(S, Msg, Key, Nonce),
			add_processed(Type, Data, Procd),
			S#state {
				gossip = NewGS
			}
	end.

%% @doc Add the ID of a new TX/block to a processed list.
add_processed({add_tx, TX}, Procd) ->
	add_processed(tx, TX, Procd);
add_processed({new_block, _, _, B, _}, Procd) ->
	add_processed(block, B, Procd);
add_processed(X, Procd) ->
	ar:report(
		[
			{could_not_ignore, X},
			{record, X}
		]),
	ok.
add_processed(tx, #tx { id = ID }, Procd) -> 
	ignore_id(ID);
add_processed(block, #block { indep_hash = Hash }, Procd) ->
	ignore_id(Hash);
add_processed(block, {_, B, _}, Procd) ->
	add_processed(block, B, Procd);
add_processed(X, Y, Procd) ->
	ar:report(
		[
			{could_not_ignore, X},
			{record, Y}
		]),
	ok.

%% @doc Find the ID of a 'data', from type.
get_id(tx, #tx { id = ID}) -> ID;
get_id(block, B) when ?IS_BLOCK(B) -> B#block.indep_hash;
get_id(block, {_, #block { indep_hash = Hash}, _}) -> Hash.

%% @doc Send an internal message externally
send_to_external(S = #state {external_peers = OrderedPeers}, {add_tx, TX}) ->
	Peers = [Y||{_,Y} <- lists:sort([ {rand:uniform(), N} || N <- OrderedPeers])],
	spawn(
		fun() ->
			ar:report(
				[
					{sending_tx_to_external_peers, ar_util:encode(TX#tx.id)},
					{peers, length(Peers)}
				]
			),
			lists:foldl(
				fun(Peer, Acc) ->				
					case (not (ar_http_iface:has_tx(Peer, TX#tx.id))) and (Acc =< ?NUM_REGOSSIP_TX) of
						true -> 
							ar_http_iface:send_new_tx(Peer, TX),
							Acc + 1;
						_ -> Acc
					end
				end,
				0,
				Peers
			)
		end
	),
	S;
send_to_external(
		S = #state {external_peers = Peers, port = Port},
		{new_block, _Peer, _Height, NewB, RecallB}) ->
	case RecallB of
		unavailable -> ok;
		_ ->
			spawn(
				fun() ->
					ar:report(
						[
							{sending_block_to_external_peers, ar_util:encode(NewB#block.indep_hash)},
							{peers, length(Peers)}
						]
					),
					lists:foreach(
						fun(Peer) ->
							ar_http_iface:send_new_block(Peer, Port, NewB, RecallB)
						end,
						Peers
					)
				end
			)
	end,
	S;
send_to_external(S, {NewGS, Msg}) ->
	send_to_external(S#state { gossip = NewGS }, Msg).

send_to_external(
		S = #state {external_peers = Peers, port = Port},
		{new_block, _Peer, _Height, NewB, RecallB},
		Key,
		Nonce) ->
	case RecallB of
		unavailable -> ok;
		_ ->
			spawn(
				fun() ->
					ar:report(
						[
							{sending_block_to_external_peers, ar_util:encode(NewB#block.indep_hash)},
							{peers, length(Peers)}
						]
					),
					lists:foreach(
						fun(Peer) ->
							ar_http_iface:send_new_block(Peer, Port, NewB, RecallB, Key, Nonce)
						end,
						Peers
					)
				end
			)
	end,
	S.

%% @doc Possibly send a new message to external peers.
do_send_to_external(S = #state { processed = Procd }, {NewGS, Msg}) ->
	NewS = (send_to_external(S#state { gossip = NewGS }, Msg)),
	add_processed(Msg, Procd),
	NewS.

%% @doc Check whether a message has already been seen.
already_processed(_Procd, _Type, {_, not_found, _}) ->
	true;
already_processed(_Procd, _Type, {_, unavailable, _}) ->
	true;
already_processed(Procd, Type, Data) ->
	already_processed(Procd, Type, Data, undefined).
already_processed(Procd, Type, Data, IP) ->
	is_id_ignored(get_id(Type, Data)).
