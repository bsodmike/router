-module(router_device_channels_worker_SUITE).

-export([all/0,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([refresh_channels_test/1,
         crashing_channel_test/1]).

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
-define(BACKOFF_MIN, timer:seconds(15)).
-define(BACKOFF_MAX, timer:minutes(5)).
-define(BACKOFF_INIT,
        {backoff:type(backoff:init(?BACKOFF_MIN, ?BACKOFF_MAX), normal),
         erlang:make_ref()}).

-record(state, {event_mgr :: pid(),
                device_worker :: pid(),
                device :: router_device:device(),
                channels = #{} :: map(),
                channels_backoffs = #{} :: map(),
                data_cache = #{} :: map(),
                channels_resp_cache = #{} :: map()}).

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
    [refresh_channels_test, crashing_channel_test].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    test_utils:init_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

refresh_channels_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    ets:insert(Tab, {no_channel, true}),

    %% Starting worker with no channels
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, DeviceWorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),
    DeviceChannelsWorkerPid = test_utils:get_device_channels_worker(DeviceID),

    %% Waiting for worker to init properly
    timer:sleep(250),

    %% Checking worker's channels, should only be "no_channel"
    State0 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"no_channel">> => router_channel:new(<<"no_channel">>,
                                                          router_no_channel,
                                                          <<"no_channel">>,
                                                          #{},
                                                          DeviceID,
                                                          DeviceChannelsWorkerPid)},
                 State0#state.channels),

    %% Add 2 http channels and force a refresh
    HTTPChannel1 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"id">> => <<"HTTP_1">>,
                     <<"name">> => <<"HTTP_NAME_1">>},
    HTTPChannel2 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"id">> => <<"HTTP_2">>,
                     <<"name">> => <<"HTTP_NAME_2">>},
    ets:insert(Tab, {no_channel, false}),
    ets:insert(Tab, {channels, [HTTPChannel1, HTTPChannel2]}),
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),
    State1 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State1#state.device, DeviceChannelsWorkerPid, HTTPChannel1),
                   <<"HTTP_2">> => convert_channel(State1#state.device, DeviceChannelsWorkerPid, HTTPChannel2)},
                 State1#state.channels),

    %% Modify HTTP Channel 2
    HTTPChannel2_1 = #{<<"type">> => <<"http">>,
                       <<"credentials">> => #{<<"headers">> => #{},
                                              <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                              <<"method">> => <<"PUT">>},
                       <<"id">> => <<"HTTP_2">>,
                       <<"name">> => <<"HTTP_NAME_2">>},
    ets:insert(Tab, {channels, [HTTPChannel1, HTTPChannel2_1]}),
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),
    State2 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(2, maps:size(State2#state.channels)),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State2#state.device, DeviceChannelsWorkerPid, HTTPChannel1),
                   <<"HTTP_2">> => convert_channel(State2#state.device, DeviceChannelsWorkerPid, HTTPChannel2_1)},
                 State2#state.channels),

    %% Remove HTTP Channel 1 and update 2 back to normal
    ets:insert(Tab, {channels, [HTTPChannel2]}),
    test_utils:force_refresh_channels(?CONSOLE_DEVICE_ID),
    State3 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_2">> => convert_channel(State3#state.device, DeviceChannelsWorkerPid, HTTPChannel2)},
                 State3#state.channels),

    gen_server:stop(DeviceWorkerPid),
    ok.

crashing_channel_test(Config) ->
    Tab = proplists:get_value(ets, Config),
    HTTPChannel1 = #{<<"type">> => <<"http">>,
                     <<"credentials">> => #{<<"headers">> => #{},
                                            <<"endpoint">> => <<"http://localhost:3000/channel">>,
                                            <<"method">> => <<"POST">>},
                     <<"id">> => <<"HTTP_1">>,
                     <<"name">> => <<"HTTP_NAME_1">>},
    ets:insert(Tab, {no_channel, false}),
    ets:insert(Tab, {channels, [HTTPChannel1]}),

    meck:new(router_http_channel, [passthrough]),
    meck:expect(router_http_channel, handle_info, fun(Msg, _State) -> erlang:throw(Msg) end),

    %% Starting worker with 1 HTTP channel
    DeviceID = ?CONSOLE_DEVICE_ID,
    {ok, DeviceWorkerPid} = router_devices_sup:maybe_start_worker(DeviceID, #{}),
    DeviceChannelsWorkerPid = test_utils:get_device_channels_worker(DeviceID),

    %% Waiting for worker to init properly
    timer:sleep(250),

    %% Check that HTTP 1 is in there
    State0 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State0#state.device, DeviceChannelsWorkerPid, HTTPChannel1)},
                 State0#state.channels),
    {Backoff0, _} = maps:get(<<"HTTP_1">>, State0#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff0)),

    %% Crash channel
    EvtMgr = State0#state.event_mgr,
    ?assert(erlang:is_pid(EvtMgr)),
    EvtMgr ! crash_http_channel,
    timer:sleep(250),

    %% Check that HTTP 1 go restarted after crash
    State1 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State1#state.device, DeviceChannelsWorkerPid, HTTPChannel1)},
                 State1#state.channels),
    {Backoff1, _} = maps:get(<<"HTTP_1">>, State1#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff1)),

    test_utils:wait_report_channel_status(#{<<"category">> => <<"channel_crash">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => DeviceID,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload">> => <<>>,
                                            <<"payload_size">> => 0,
                                            <<"port">> => '_',
                                            <<"devaddr">> => '_',
                                            <<"hotspots">> => [],
                                            <<"channels">> => [#{<<"id">> => <<"HTTP_1">>,
                                                                 <<"name">> => <<"HTTP_NAME_1">>,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"error">>,
                                                                 <<"description">> => '_'}]}),

    %% Crash channel and crash on init
    meck:expect(router_http_channel, init, fun(_Args) -> {error, init_failed} end),
    timer:sleep(10),
    EvtMgr ! crash_http_channel,
    timer:sleep(250),

    %% Check that HTTP 1 is gone and that backoff increased
    State2 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{}, State2#state.channels),
    {Backoff2, _} = maps:get(<<"HTTP_1">>, State2#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN * 2, backoff:get(Backoff2)),
    test_utils:wait_report_channel_status(#{<<"category">> => <<"channel_crash">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => DeviceID,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload">> => <<>>,
                                            <<"payload_size">> => 0,
                                            <<"port">> => '_',
                                            <<"devaddr">> => '_',
                                            <<"hotspots">> => [],
                                            <<"channels">> => [#{<<"id">> => <<"HTTP_1">>,
                                                                 <<"name">> => <<"HTTP_NAME_1">>,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"error">>,
                                                                 <<"description">> => '_'}]}),
    test_utils:wait_report_channel_status(#{<<"category">> => <<"channel_start_error">>,
                                            <<"description">> => '_',
                                            <<"reported_at">> => fun erlang:is_integer/1,
                                            <<"device_id">> => DeviceID,
                                            <<"frame_up">> => fun erlang:is_integer/1,
                                            <<"frame_down">> => fun erlang:is_integer/1,
                                            <<"payload">> => <<>>,
                                            <<"payload_size">> => 0,
                                            <<"port">> => '_',
                                            <<"devaddr">> => '_',
                                            <<"hotspots">> => [],
                                            <<"channels">> => [#{<<"id">> => <<"HTTP_1">>,
                                                                 <<"name">> => <<"HTTP_NAME_1">>,
                                                                 <<"reported_at">> => fun erlang:is_integer/1,
                                                                 <<"status">> => <<"error">>,
                                                                 <<"description">> => '_'}]}),

    %% Fix crash and wait for HTTP channel to come back
    meck:unload(router_http_channel),
    timer:sleep(?BACKOFF_MIN * 2 + 250),
    State3 = sys:get_state(DeviceChannelsWorkerPid),
    ?assertEqual(#{<<"HTTP_1">> => convert_channel(State3#state.device, DeviceChannelsWorkerPid, HTTPChannel1)},
                 State1#state.channels),
    {Backoff3, _} = maps:get(<<"HTTP_1">>, State3#state.channels_backoffs),
    ?assertEqual(?BACKOFF_MIN, backoff:get(Backoff3)),

    gen_server:stop(DeviceWorkerPid),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------


-spec convert_channel(router_device:device(), pid(), map()) -> false | router_channel:channel().
convert_channel(Device, Pid, #{<<"type">> := <<"http">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_http_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{url =>  kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             headers => maps:to_list(kvc:path([<<"credentials">>, <<"headers">>], JSONChannel)),
             method => list_to_existing_atom(binary_to_list(kvc:path([<<"credentials">>, <<"method">>], JSONChannel)))},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid),
    Channel;
convert_channel(Device, Pid, #{<<"type">> := <<"mqtt">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_mqtt_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{endpoint => kvc:path([<<"credentials">>, <<"endpoint">>], JSONChannel),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid),
    Channel;
convert_channel(Device, Pid, #{<<"type">> := <<"aws">>}=JSONChannel) ->
    ID = kvc:path([<<"id">>], JSONChannel),
    Handler = router_aws_channel,
    Name = kvc:path([<<"name">>], JSONChannel),
    Args = #{aws_access_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_access_key">>], JSONChannel)),
             aws_secret_key => binary_to_list(kvc:path([<<"credentials">>, <<"aws_secret_key">>], JSONChannel)),
             aws_region => binary_to_list(kvc:path([<<"credentials">>, <<"aws_region">>], JSONChannel)),
             topic => kvc:path([<<"credentials">>, <<"topic">>], JSONChannel)},
    DeviceID = router_device:id(Device),
    Channel = router_channel:new(ID, Handler, Name, Args, DeviceID, Pid),
    Channel;
convert_channel(_Device, _Pid, _Channel) ->
    false.
