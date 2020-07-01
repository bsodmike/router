-module(router_console_dc_tracker).

-behavior(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         refill/3,
         has_enough_dc/3,
         current_balance/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS, router_console_dc_tracker_ets).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec refill(OrgID :: binary(), Nonce :: non_neg_integer(), Balance :: non_neg_integer()) -> ok.
refill(OrgID, Nonce, Balance) ->
    case lookup(OrgID) of
        {error, not_found} ->
            lager:info("refiling ~p with ~p @ epoch ~p", [OrgID, Balance, Nonce]),
            insert(OrgID, Balance, Nonce);
        {ok, OldBalance, _OldNonce} ->
            lager:info("refiling ~p with ~p @ epoch ~p (old: ~p)", [OrgID, Balance + OldBalance, Nonce, _OldNonce]),
            insert(OrgID, Balance + OldBalance, Nonce)
    end.

-spec has_enough_dc(OrgID :: binary(), PayloadSize :: non_neg_integer(), Chain :: blockchain:blockchain()) ->
    {true, non_neg_integer(), non_neg_integer()} | false.
has_enough_dc(OrgID, PayloadSize, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_utils:calculate_dc_amount(Ledger, PayloadSize) of
        {error, _Reason} ->
            lager:warning("failed to calculate dc amount ~p", [_Reason]),
            false;
        DCAmount ->
            case lookup(OrgID) of
                {error, not_found} ->
                    false;
                {ok, Balance0, Nonce} ->
                    Balance1 = Balance0-DCAmount,
                    case Balance1 >= 0 of
                        false ->
                            false;
                        true ->
                            ok = insert(OrgID, Balance1, Nonce),
                            {true, Balance1, Nonce}
                    end

            end
    end.

-spec current_balance(OrgID :: binary()) -> {non_neg_integer(), non_neg_integer()}.
current_balance(OrgID) ->
    case lookup(OrgID) of
        {error, not_found} -> {0, 0};
        {ok, Balance, Nonce} -> {Balance, Nonce}
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ets:new(?ETS, [public, named_table, set]),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

lookup(OrgID) ->
    case ets:lookup(?ETS, OrgID) of
        [] -> {error, not_found};
        [{OrgID, {Balance, Nonce}}] -> {ok, Balance, Nonce}
    end.

insert(OrgID, Balance, Nonce) ->
    true = ets:insert(?ETS, {OrgID, {Balance, Nonce}}),
    ok.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

refill_test() ->
    _  = ets:new(?ETS, [public, named_table, set]),
    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 100,
    ?assertEqual({error, not_found}, lookup(OrgID)),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({ok, Balance, Nonce}, lookup(OrgID)),
    ets:delete(?ETS),
    ok.

has_enough_dc_test() ->
    _  = ets:new(?ETS, [public, named_table, set]),
    meck:new(blockchain, [passthrough]),
    meck:expect(blockchain, ledger, fun(_) -> undefined end),
    meck:new(blockchain_utils, [passthrough]),
    meck:expect(blockchain_utils, calculate_dc_amount, fun(_, _) -> 2 end),

    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 2,
    ?assertEqual(false, has_enough_dc(OrgID, 48, chain)),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({true, 0, 1}, has_enough_dc(OrgID, 48, chain)),
    ?assertEqual(false, has_enough_dc(OrgID, 48, chain)),

    ets:delete(?ETS),
    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain),
    ?assert(meck:validate(blockchain_utils)),
    meck:unload(blockchain_utils),
    ok.

current_balance_test() ->
    _  = ets:new(?ETS, [public, named_table, set]),
    OrgID = <<"ORG_ID">>,
    Nonce = 1,
    Balance = 100,
    ?assertEqual({0, 0}, current_balance(OrgID)),
    ?assertEqual(ok, refill(OrgID, Nonce, Balance)),
    ?assertEqual({100, 1}, current_balance(OrgID)),
    ets:delete(?ETS),
    ok.


-endif.