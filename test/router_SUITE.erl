-module(router_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([dupes_test/1,
         join_test/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").
-include("utils/console_test.hrl").

-define(CONSOLE_URL, <<"http://localhost:3000">>).
-define(DECODE(A), jsx:decode(A, [return_maps])).
-define(APPEUI, <<0,0,0,2,0,0,0,1>>).
-define(DEVEUI, <<0,0,0,0,0,0,0,1>>).
-define(ETS, ?MODULE).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [dupes_test,
     join_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(TestCase, Config) ->
    BaseDir = erlang:atom_to_list(TestCase),
    ok = application:set_env(router, base_dir, BaseDir ++ "/router_swarm_data"),
    ok = application:set_env(router, port, 3615),
    ok = application:set_env(router, router_device_api_module, router_device_api_console),
    ok = application:set_env(router, console_endpoint, ?CONSOLE_URL),
    ok = application:set_env(router, console_secret, <<"secret">>),
    filelib:ensure_dir(BaseDir ++ "/log"),
    ok = application:set_env(lager, log_root, BaseDir ++ "/log"),
    Tab = ets:new(?ETS, [public, set]),
    AppKey = crypto:strong_rand_bytes(16),
    ElliOpts = [
                {callback, console_callback},
                {callback_args, #{forward => self(), ets => Tab,
                                  app_key => AppKey, app_eui => ?APPEUI, dev_eui => ?DEVEUI}},
                {port, 3000}
               ],
    {ok, Pid} = elli:start_link(ElliOpts),
    {ok, _} = application:ensure_all_started(router),
    [{app_key, AppKey}, {ets, Tab}, {elli, Pid}, {base_dir, BaseDir}|Config].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Pid = proplists:get_value(elli, Config),
    {ok, Acceptors} = elli:get_acceptors(Pid),
    ok = elli:stop(Pid),
    timer:sleep(500),
    [catch erlang:exit(A, kill) || A <- Acceptors],
    ok = application:stop(router),
    ok = application:stop(lager),
    e2qc:teardown(console_cache),
    ok = application:stop(e2qc),
    ok = application:stop(throttle),
    Tab = proplists:get_value(ets, Config),
    ets:delete(Tab),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

dupes_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    AppKey = proplists:get_value(app_key, Config),
    ets:insert(Tab, {show_dupes, true}),
    BaseDir = proplists:get_value(base_dir, Config),
    Swarm = test_utils:start_swarm(BaseDir, dupes_test_swarm, 3617),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    {ok, Stream} = libp2p_swarm:dial_framed_stream(Swarm,
                                                   Address,
                                                   router_handler_test:version(),
                                                   router_handler_test,
                                                   [self()]),
    PubKeyBin1 = libp2p_swarm:pubkey_bin(Swarm),
    {ok, HotspotName1} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream ! {send, test_utils:join_packet(PubKeyBin1, AppKey, JoinNonce)},
    timer:sleep(?JOIN_DELAY),

    %% Waiting for console repor status sent
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName1)}),
    %% Waiting for reply resp form router
    test_utils:wait_state_channel_message(250),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    {ok, WorkerPid} = router_devices_sup:lookup_device_worker(WorkerID),
    Msg0 = {false, 1, <<"somepayload">>},
    router_device_worker:queue_message(WorkerPid, Msg0),
    Msg1 = {true, 2, <<"someotherpayload">>},
    router_device_worker:queue_message(WorkerPid, Msg1),

    %% Send 2 similar packet to make it look like it's coming from 2 diff hotspot
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin1, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    #{public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    PubKeyBin2 = libp2p_crypto:pubkey_to_bin(PubKey),
    {ok, HotspotName2} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin2)),
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 0)},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName1),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 0,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName1),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 0,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 0,
                                            <<"frame_down">> => 0,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    {ok, Reply1} = test_utils:wait_state_channel_message(Msg0, Device0, erlang:element(3, Msg0), ?UNCONFIRMED_DOWN, 1, 0, 1, 0),
    ct:pal("Reply ~p", [Reply1]),
    true = lists:keymember(link_adr_req, 1, Reply1#frame.fopts),

    %% We had message in the queue so we expect a device status down
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"down">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName1)}),

    %% Make sure we did not get a duplicate
    receive
        {client_data, _, _Data2} ->
            ct:fail("double_reply ~p", [blockchain_state_channel_v1_pb:decode_msg(_Data2, blockchain_state_channel_message_v1_pb)])
    after 0 ->
            ok
    end,

    Stream ! {send, test_utils:frame_packet(?CONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 1)},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 1,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 1,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"ack">>,
                                           <<"frame_up">> => 1,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName2)}),
    {ok, Reply2} = test_utils:wait_state_channel_message(Msg1, Device0, erlang:element(3, Msg1), ?CONFIRMED_DOWN, 0, 1, 2, 1),
    %% check we're still getting ADR commands
    true = lists:keymember(link_adr_req, 1, Reply2#frame.fopts),

    %% check we get the second downlink again because we didn't ACK it
    %% also ack the ADR adjustments
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 2, #{fopts => [{link_adr_ans, 1, 1, 1}]})},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 2,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 2,
                                            <<"frame_down">> => 1,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"down">>,
                                           <<"frame_up">> => 2,
                                           <<"frame_down">> => 1,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName2)}),
    {ok, Reply3} = test_utils:wait_state_channel_message(Msg1, Device0, erlang:element(3, Msg1), ?CONFIRMED_DOWN, 0, 0, 2, 1),
    %% check NOT we're still getting ADR commands
    false = lists:keymember(link_adr_req, 1, Reply3#frame.fopts),

    %% ack the packet, we don't expect a reply here
    Stream ! {send, test_utils:frame_packet(?UNCONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 2, #{should_ack => true})},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 2,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 2,
                                            <<"frame_down">> => 2,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    timer:sleep(1000),
    receive
        {client_data, _,  _Data3} ->
            ct:fail("unexpected_reply ~p", [blockchain_state_channel_v1_pb:decode_msg(_Data3, blockchain_state_channel_message_v1_pb)])
    after 0 ->
            ok
    end,

    %% send a confimed up to provoke a 'bare ack'
    Stream ! {send, test_utils:frame_packet(?CONFIRMED_UP, PubKeyBin2, router_device:nwk_s_key(Device0), router_device:app_s_key(Device0), 3)},
    test_utils:wait_channel_data(#{<<"metadata">> => #{<<"labels">> => ?CONSOLE_LABELS},
                                   <<"app_eui">> => lorawan_utils:binary_to_hex(?APPEUI),
                                   <<"dev_eui">> => lorawan_utils:binary_to_hex(?DEVEUI),
                                   <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                   <<"id">> => ?CONSOLE_DEVICE_ID,
                                   <<"name">> => ?CONSOLE_DEVICE_NAME,
                                   <<"payload">> => <<>>,
                                   <<"port">> => 1,
                                   <<"rssi">> => 0.0,
                                   <<"sequence">> => 3,
                                   <<"snr">> => 0.0,
                                   <<"spreading">> => <<"SF8BW125">>,
                                   <<"timestamp">> => 0}),
    test_utils:wait_report_channel_status(#{<<"status">> => <<"success">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"category">> => <<"up">>,
                                            <<"frame_up">> => 3,
                                            <<"frame_down">> => 2,
                                            <<"hotspot_name">> => erlang:list_to_binary(HotspotName2),
                                            <<"rssi">> => 0.0,
                                            <<"snr">> => 0.0,
                                            <<"payload_size">> => 0,
                                            <<"payload">> => <<>>,
                                            <<"channel_id">> => ?CONSOLE_HTTP_CHANNEL_ID,
                                            <<"channel_name">> => ?CONSOLE_HTTP_CHANNEL_NAME}),
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"ack">>,
                                           <<"frame_up">> => 3,
                                           <<"frame_down">> => 3,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName2)}),
    {ok, Reply4} = test_utils:wait_state_channel_message(Msg1, Device0, <<>>, ?UNCONFIRMED_DOWN, 0, 1, undefined, 2),

    %% check NOT we're still getting ADR commands
    false = lists:keymember(link_adr_req, 1, Reply4#frame.fopts),

    libp2p_swarm:stop(Swarm),
    ok.

join_test(Config) ->
    AppKey = proplists:get_value(app_key, Config),
    BaseDir = proplists:get_value(base_dir, Config),
    {ok, RouterSwarm} = router_p2p:swarm(),
    [Address|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    Swarm0 = test_utils:start_swarm(BaseDir, join_test_swarm_0, 3620),
    Swarm1 = test_utils:start_swarm(BaseDir, join_test_swarm_1, 3621),
    PubKeyBin0 = libp2p_swarm:pubkey_bin(Swarm0),
    PubKeyBin1 = libp2p_swarm:pubkey_bin(Swarm1),
    {ok, Stream0} = libp2p_swarm:dial_framed_stream(Swarm0,
                                                    Address,
                                                    router_handler_test:version(),
                                                    router_handler_test,
                                                    [self(), PubKeyBin0]),
    {ok, Stream1} = libp2p_swarm:dial_framed_stream(Swarm1,
                                                    Address,
                                                    router_handler_test:version(),
                                                    router_handler_test,
                                                    [self(), PubKeyBin1]),


    Stream0 ! {send, test_utils:join_packet(PubKeyBin0, crypto:strong_rand_bytes(16), crypto:strong_rand_bytes(2), -100)},

    receive
        {client_data, _,  _Data3} ->
            ct:fail("join didn't fail")
    after 0 ->
            ok
    end,

    %% Send join packet
    JoinNonce = crypto:strong_rand_bytes(2),
    Stream0 ! {send, test_utils:join_packet(PubKeyBin0, AppKey, JoinNonce, -100)},
    timer:sleep(500),
    Stream1 ! {send, test_utils:join_packet(PubKeyBin1, AppKey, JoinNonce, -80)},
    timer:sleep(?JOIN_DELAY),

    {ok, HotspotName1} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKeyBin1)),

    %% Waiting for console repor status sent (it should select PubKeyBin1 cause better rssi)
    test_utils:wait_report_device_status(#{<<"status">> => <<"success">>,
                                           <<"description">> => '_',
                                           <<"reported_at">> => fun erlang:is_integer/1,
                                           <<"category">> => <<"activation">>,
                                           <<"frame_up">> => 0,
                                           <<"frame_down">> => 0,
                                           <<"hotspot_name">> => erlang:list_to_binary(HotspotName1)}),
    %% Waiting for reply resp form router
    {_NetID, _DevAddr, _DLSettings, _RxDelay, NwkSKey, AppSKey} = test_utils:wait_for_join_resp(PubKeyBin1, AppKey, JoinNonce),

    %% Check that device is in cache now
    {ok, DB, [_, CF]} = router_db:get(),
    WorkerID = router_devices_sup:id(?CONSOLE_DEVICE_ID),
    {ok, Device0} = router_device:get(DB, CF, WorkerID),

    ?assertEqual(router_device:nwk_s_key(Device0), NwkSKey),
    ?assertEqual(router_device:app_s_key(Device0), AppSKey),
    ?assertEqual(router_device:join_nonce(Device0), JoinNonce),

    libp2p_swarm:stop(Swarm0),
    libp2p_swarm:stop(Swarm1),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

