%%%-------------------------------------------------------------------
%% @doc
%% == Router State Channels Worker ==
%%
%% * Responsible for state channel management
%% * Always tries to keep two state channels alive at all times, tracked via active_count
%% * If there is no OUI configured in app config, do nothing on add block events
%% * If there is an OUI configured in app config and a chain is available:
%%
%%      ** If there is no active_count, initialize two state channels
%%      ** If active_count = 1, figure out next nonce and fire off next state_channel
%%      with expiration set to twice the current max nonce state channel
%%      ** If active_count = 2, stand by
%%
%% @end
%%%-------------------------------------------------------------------
-module(router_sc_worker).

-behavior(gen_server).

-include_lib("blockchain/include/blockchain_utils.hrl").

%% ------------------------------------------------------------------
%% API
%% ------------------------------------------------------------------
-export([
         start_link/1,
         is_active/0,
         active_count/0
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
%% TODO: Configure via app env
-define(EXPIRATION, 45).

-record(state, {
                oui = undefined :: undefined | non_neg_integer(),
                chain = undefined :: undefined | blockchain:blockchain(),
                is_active = false :: boolean(),
                active_count = 0 :: 0 | 1 | 2
               }).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec is_active() -> boolean().
is_active() ->
    gen_server:call(?SERVER, is_active).

-spec active_count() -> 0 | 1 | 2.
active_count() ->
    gen_server:call(?SERVER, active_count).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    %% TODO: Not really sure where exactly to install this handler at tbh...
    ok = router_handler:add_stream_handler(blockchain_swarm:swarm()),
    ok = blockchain_event:add_handler(self()),
    erlang:send_after(500, self(), post_init),
    {ok, #state{active_count=get_active_count()}}.

handle_call(is_active, _From, State) ->
    {reply, State#state.is_active, State};
handle_call(active_count, _From, State) ->
    {reply, State#state.active_count, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(post_init, #state{chain=undefined}=State) ->
    %% No chain
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            case router_utils:get_router_oui(Chain) of
                undefined ->
                    {noreply, State#state{chain=Chain}};
                OUI ->
                    %% We have a chain and an oui on chain, set is_active to true
                    {noreply, State#state{chain=Chain, oui=OUI, is_active=true}}
            end
    end;
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{chain=undefined}=State) ->
    %% Got block without a chain, wut?
    erlang:send_after(500, self(), post_init),
    {noreply, State};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{is_active=false, chain=Chain}=State) ->
    %% We're inactive, check if we have an oui
    case router_utils:get_router_oui(Chain) of
        undefined ->
            %% stay inactive
            {noreply, State};
        OUI ->
            %% activate
            {noreply, State#state{oui=OUI, is_active=true}}
    end;
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{active_count=0, is_active=true}=State) ->
    lager:info("active_count = 0, initializing two state_channels"),
    ok = init_state_channels(State),
    {noreply, State#state{active_count=get_active_count()}};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, Ledger}}, #state{active_count=1, is_active=true}=State) ->
    lager:info("active_count = 1, opening next state_channel"),
    ok = open_next_state_channel(State, Ledger),
    {noreply, State#state{active_count=get_active_count()}};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{active_count=2, is_active=true}=State) ->
    %% Don't do anything
    lager:info("active_count = 2, standing by"),
    {noreply, State#state{active_count=get_active_count()}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Helper funs
%% ------------------------------------------------------------------

-spec init_state_channels(State :: state()) -> ok.
init_state_channels(#state{oui=OUI, chain=Chain}) ->
    %% We have no state channels at all on the ledger
    PubkeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    case find_max_nonce_sc(PubkeyBin, blockchain:ledger(Chain)) of
        undefined ->
            %% no scs exist for this router
            ok = create_and_send_sc_open_txn(PubkeyBin, SigFun, 1, OUI, ?EXPIRATION),
            ok = create_and_send_sc_open_txn(PubkeyBin, SigFun, 2, OUI, ?EXPIRATION * 2);
        MaxNonceSC ->
            ExistingMaxNonce = blockchain_ledger_state_channel_v1:nonce(MaxNonceSC),
            ok = create_and_send_sc_open_txn(PubkeyBin, SigFun, ExistingMaxNonce + 1, OUI, ?EXPIRATION),
            ok = create_and_send_sc_open_txn(PubkeyBin, SigFun, ExistingMaxNonce + 2, OUI, ?EXPIRATION * 2)
    end.

-spec open_next_state_channel(State :: state(), Ledger :: blockchain_ledger_v1:ledger()) -> ok.
open_next_state_channel(#state{oui=OUI}, Ledger) ->
    %% Get my pubkey_bin and sigfun
    PubkeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    case find_max_nonce_sc(PubkeyBin, Ledger) of
        undefined ->
            %% how did you even get here?
            ok;
        MaxNonceSC ->
            Nonce = blockchain_ledger_state_channel_v1:nonce(MaxNonceSC),
            ExpireAtBlock = blockchain_ledger_state_channel_v1:expire_at_block(MaxNonceSC),
            create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce + 1, OUI, ExpireAtBlock + 2 * ?EXPIRATION)
    end.

-spec create_and_send_sc_open_txn(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                                  SigFun :: libp2p_crypto:sig_fun(),
                                  Nonce :: pos_integer(),
                                  OUI :: non_neg_integer(),
                                  Expiration :: pos_integer()) -> ok.
create_and_send_sc_open_txn(PubkeyBin, SigFun, Nonce, OUI, Expiration) ->
    %% Create and open a new state_channel
    %% With its expiration set to 2 * Expiration of the one with max nonce
    ID = crypto:strong_rand_bytes(32),
    Txn = blockchain_txn_state_channel_open_v1:new(ID, PubkeyBin, Expiration, OUI, Nonce),
    SignedTxn = blockchain_txn_state_channel_open_v1:sign(Txn, SigFun),
    lager:info("Opening state channel for router: ~p, oui: ~p, nonce: ~p", [?TO_B58(PubkeyBin), OUI, Nonce]),
    blockchain_worker:submit_txn(SignedTxn).

-spec get_active_count() -> non_neg_integer().
get_active_count() ->
    map_size(blockchain_state_channels_server:state_channels()).

-spec find_max_nonce_sc(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                        Ledger :: blockchain_ledger_v1:ledger()) -> undefined | blockchain_ledger_state_channel_v1:state_channel().
find_max_nonce_sc(PubkeyBin, Ledger) ->
    %% Sort currently active state_channels by nonce to fire the next one
    SCSortFun = fun({_ID1, SC1}, {_ID2, SC2}) ->
                        blockchain_ledger_state_channel_v1:nonce(SC1) >= blockchain_ledger_state_channel_v1:nonce(SC2)
                end,

    %% Find the sc with the max nonce currently
    {ok, LedgerSCs} = blockchain_ledger_v1:find_scs_by_owner(PubkeyBin, Ledger),

    case LedgerSCs of
        M when map_size(M) == 0 ->
            undefined;
        _ ->
            {_, SC} = hd(lists:sort(SCSortFun, maps:to_list(LedgerSCs))),
            SC
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

%% TODO: add some eunits here...

-endif.
