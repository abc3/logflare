defmodule Logflare.Backends.BigQueryAdaptorTest do
  use Logflare.DataCase
  use ExUnitProperties

  alias Logflare.Backends
  alias Logflare.Backends.SourceSup
  alias Logflare.Backends.Adaptor.BigQueryAdaptor
  alias Logflare.SystemMetrics.AllLogsLogged
  alias GoogleApi.CloudResourceManager.V1.Model

  setup do
    start_supervised!(AllLogsLogged)
    insert(:plan)
    :ok
  end

  describe "default bigquery backend" do
    test "can ingest into source without creating a BQ backend" do
      user = insert(:user)
      source = insert(:source, user: user)
      start_supervised!({SourceSup, source})
      log_event = build(:log_event, source: source)
      pid = self()

      Logflare.Google.BigQuery
      |> expect(:stream_batch!, fn _, _ ->
        send(pid, :streamed)
        {:ok, %GoogleApi.BigQuery.V2.Model.TableDataInsertAllResponse{insertErrors: nil}}
      end)

      assert {:ok, 1} = Backends.ingest_logs([log_event], source)

      TestUtils.retry_assert(fn ->
        assert_receive :streamed, 2500
      end)

      :timer.sleep(1000)
    end

    test "does not use LF managed BQ if legacy user BQ config is set" do
      user = insert(:user, bigquery_project_id: "some-project", bigquery_dataset_id: "some-id")
      source = insert(:source, user: user)
      start_supervised!({SourceSup, source})
      log_event = build(:log_event, source: source)

      pid = self()

      Logflare.Google.BigQuery
      |> expect(:stream_batch!, fn arg, _ ->
        assert arg.bigquery_project_id == "some-project"
        assert arg.bigquery_dataset_id == "some-id"
        send(pid, :ok)
        {:ok, %GoogleApi.BigQuery.V2.Model.TableDataInsertAllResponse{insertErrors: nil}}
      end)

      assert {:ok, 1} = Backends.ingest_logs([log_event], source)

      TestUtils.retry_assert(fn ->
        assert_receive :ok, 2500
      end)

      :timer.sleep(1000)
    end
  end

  describe "custom bigquery backend" do
    setup do
      config = %{
        project_id: "some-project",
        dataset_id: "some-dataset"
      }

      source = insert(:source, user: insert(:user))

      backend =
        insert(:backend,
          type: :bigquery,
          sources: [source],
          config: config
        )

      start_supervised!({SourceSup, source})

      {:ok, source: source, backend: backend}
    end

    test "plain ingest", %{source: source} do
      log_event = build(:log_event, source: source)
      pid = self()

      Logflare.Google.BigQuery
      |> expect(:stream_batch!, fn _, _ ->
        send(pid, :streamed)
        {:ok, %GoogleApi.BigQuery.V2.Model.TableDataInsertAllResponse{insertErrors: nil}}
      end)

      assert {:ok, _} = Backends.ingest_logs([log_event], source)

      assert_receive :streamed, 2500
      :timer.sleep(1000)
    end

    test "update table", %{source: source} do
      log_event = build(:log_event, source: source, test: "data")
      pid = self()

      Logflare.Google.BigQuery
      |> stub(:stream_batch!, fn _, _ ->
        {:ok, %GoogleApi.BigQuery.V2.Model.TableDataInsertAllResponse{insertErrors: nil}}
      end)

      GoogleApi.BigQuery.V2.Api.Tables
      |> expect(:bigquery_tables_patch, fn _conn,
                                           _project_id,
                                           _dataset_id,
                                           _table_name,
                                           [body: _body] ->
        send(pid, :patched)
        {:ok, %{}}
      end)

      Logflare.Mailer
      |> stub(:deliver, fn _ -> :ok end)

      assert {:ok, _} = Backends.ingest_logs([log_event], source)

      assert_receive :patched, 2500
      :timer.sleep(1000)
    end

    test "bug: invalid json encode update table", %{
      source: source,
      backend: backend
    } do
      source_id = source.id
      backend_id = backend.id
      log_event = build(:log_event, source: source, test: <<97, 98, 99, 222, 126, 199, 31, 89>>)
      pid = self()
      ref = make_ref()

      Logflare.Google.BigQuery
      |> stub(:stream_batch!, fn _, _ ->
        send(pid, ref)
        {:ok, %GoogleApi.BigQuery.V2.Model.TableDataInsertAllResponse{insertErrors: nil}}
      end)

      GoogleApi.BigQuery.V2.Api.Tables
      |> stub(:bigquery_tables_patch, fn _conn,
                                         _project_id,
                                         _dataset_id,
                                         _table_name,
                                         [body: _body] ->
        {:ok, %{}}
      end)

      Logflare.Mailer
      |> stub(:deliver, fn _ -> :ok end)

      assert {:ok, _} = Backends.ingest_logs([log_event], source)

      assert {:ok, %{len: 1}} = Backends.cache_local_buffer_lens(source_id, nil)
      assert {:ok, %{len: 1}} = Backends.cache_local_buffer_lens(source_id, backend_id)
      :timer.sleep(2000)

      TestUtils.retry_assert(fn ->
        assert_receive ^ref
      end)

      {:ok, %{queues: queues}} = Backends.cache_local_buffer_lens(source_id, nil)

      assert Enum.find_value(queues, fn
               {{^source_id, nil, nil}, count} -> count
               _ -> nil
             end) == 0

      {:ok, %{queues: queues}} = Backends.cache_local_buffer_lens(source_id, backend_id)

      assert Enum.find_value(queues, fn
               {{^source_id, ^backend_id, nil}, count} -> count
               _ -> nil
             end) == 0
    end
  end

  describe "handle_resolve_count/3" do
    test "resolve_count will increase counts when queue size is above threshold" do
      check all pipeline_count <- integer(0..100),
                queue_size <- integer(505..10000),
                avg_rate <- integer(100..10_000),
                last <- member_of([nil, NaiveDateTime.utc_now()]) do
        state = %{
          pipeline_count: pipeline_count,
          max_pipelines: 101,
          last_count_increase: last,
          last_count_decrease: last
        }

        desired =
          BigQueryAdaptor.handle_resolve_count(
            state,
            %{
              {1, 2, nil} => 0,
              {1, 2, make_ref()} => queue_size
            },
            avg_rate
          )

        assert desired > pipeline_count
      end
    end

    test "resolve_count will increase counts when startup queue is non-empty" do
      check all pipeline_count <- integer(0..100),
                queue_size <- integer(1..250),
                startup_queue_size <- integer(5000..10000),
                avg_rate <- integer(100..10_000),
                last <- member_of([nil, NaiveDateTime.utc_now()]) do
        state = %{
          pipeline_count: pipeline_count,
          max_pipelines: 101,
          last_count_increase: last,
          last_count_decrease: last
        }

        desired =
          BigQueryAdaptor.handle_resolve_count(
            state,
            %{
              {1, 2, nil} => startup_queue_size,
              {1, 2, make_ref()} => queue_size
            },
            avg_rate
          )

        assert desired - pipeline_count > 5
      end
    end

    test "resolve_count increases startup queue by 1 if less than 500 " do
      check all pipeline_count <- constant(0),
                startup_queue_size <- integer(1..444),
                avg_rate <- integer(1..500) do
        state = %{
          pipeline_count: pipeline_count,
          max_pipelines: 101,
          last_count_increase: NaiveDateTime.utc_now(),
          last_count_decrease: NaiveDateTime.utc_now()
        }

        desired =
          BigQueryAdaptor.handle_resolve_count(
            state,
            %{
              {1, 2, nil} => startup_queue_size
            },
            avg_rate
          )

        assert desired - pipeline_count == 1
      end
    end

    test "resolve_count will decrease counts" do
      check all pipeline_count <- integer(2..100),
                queue_size <- integer(0..49),
                startup_queue_size <- constant(0),
                avg_rate <- integer(0..10_000),
                since <- integer(71..100) do
        state = %{
          pipeline_count: pipeline_count,
          max_pipelines: 101,
          last_count_increase: NaiveDateTime.utc_now(),
          last_count_decrease: NaiveDateTime.utc_now() |> NaiveDateTime.add(-since)
        }

        desired =
          BigQueryAdaptor.handle_resolve_count(
            state,
            %{
              {1, 2, nil} => startup_queue_size,
              {1, 2, make_ref()} => queue_size
            },
            avg_rate
          )

        assert desired < pipeline_count
        assert desired != 0
      end
    end

    test "resolve_count scale to zero" do
      check all pipeline_count <- constant(1),
                queue_size <- constant(0),
                startup_queue_size <- constant(0),
                avg_rate <- constant(0),
                since <- integer(360..1000) do
        state = %{
          pipeline_count: pipeline_count,
          max_pipelines: 101,
          last_count_increase: NaiveDateTime.utc_now(),
          last_count_decrease: NaiveDateTime.utc_now() |> NaiveDateTime.add(-since)
        }

        desired =
          BigQueryAdaptor.handle_resolve_count(
            state,
            %{
              {1, 2, nil} => startup_queue_size,
              {1, 2, make_ref()} => queue_size
            },
            avg_rate
          )

        assert desired < pipeline_count
        assert desired == 0
      end
    end
  end

  describe "managed service accounts" do
    setup do
      original_pool_size =
        Application.get_env(:logflare, :bigquery_backend_adaptor)[
          :managed_service_account_pool_size
        ]

      Application.put_env(:logflare, :bigquery_backend_adaptor,
        managed_service_account_pool_size: 2
      )

      on_exit(fn ->
        Application.put_env(:logflare, :bigquery_backend_adaptor,
          managed_service_account_pool_size: original_pool_size
        )
      end)

      :ok
    end

    test "create_managed_service_accounts/0" do
      ref = self()
      # Mock IAM API calls for listing existing service accounts
      expect(GoogleApi.IAM.V1.Api.Projects, :iam_projects_service_accounts_list, fn
        _conn, "projects/" <> _project_id, _opts ->
          {:ok, %{accounts: [], nextPageToken: nil}}
      end)

      # Mock IAM API calls for creating new service accounts
      expect(GoogleApi.IAM.V1.Api.Projects, :iam_projects_service_accounts_create, 2, fn
        _conn, "projects/" <> project_id, opts ->
          # Assert the body has the correct account ID
          assert %{accountId: account_id} = opts[:body]
          assert account_id =~ ~r/logflare-managed-\d+/
          send(ref, {:created, account_id})

          {:ok,
           %GoogleApi.IAM.V1.Model.ServiceAccount{
             email: "#{account_id}@#{project_id}.iam.gserviceaccount.com"
           }}
      end)

      assert {:ok, [_, _]} = BigQueryAdaptor.create_managed_service_accounts()

      assert_receive {:created, "logflare-managed-0"}, 1000
      assert_receive {:created, "logflare-managed-1"}, 1000
    end

    test "update_iam_policy/0" do
      pid = self()
      # Mock IAM API calls for listing existing service accounts
      expect(GoogleApi.IAM.V1.Api.Projects, :iam_projects_service_accounts_list, fn
        _conn, "projects/" <> _project_id, _opts ->
          {:ok,
           %{
             accounts: [
               %GoogleApi.IAM.V1.Model.ServiceAccount{
                 email: "logflare-managed-0@some-project.iam.gserviceaccount.com",
                 name:
                   "projects/some-project/serviceAccounts/logflare-managed-0@some-project.iam.gserviceaccount.com"
               }
             ],
             nextPageToken: nil
           }}
      end)

      expect(
        GoogleApi.CloudResourceManager.V1.Api.Projects,
        :cloudresourcemanager_projects_set_iam_policy,
        fn _conn, _project_number, [body: body] ->
          send(pid, body.policy.bindings)
          {:ok, ""}
        end
      )

      BigQueryAdaptor.update_iam_policy()

      assert_received [_ | _] = bindings

      assert Enum.any?(bindings, fn binding ->
               Enum.any?(binding.members, fn member ->
                 member =~ "logflare-managed-"
               end)
             end)
    end
  end

  describe "managed service accounts is disabled" do
    setup do
      original_pool_size =
        Application.get_env(:logflare, :bigquery_backend_adaptor)[
          :managed_service_account_pool_size
        ]

      Application.put_env(:logflare, :bigquery_backend_adaptor,
        managed_service_account_pool_size: 0
      )

      on_exit(fn ->
        Application.put_env(:logflare, :bigquery_backend_adaptor,
          managed_service_account_pool_size: original_pool_size
        )
      end)

      :ok
    end

    test "create_managed_service_accounts/0 should not provision service accounts" do
      reject(&GoogleApi.IAM.V1.Api.Projects.iam_projects_service_accounts_list/3)
      reject(&GoogleApi.IAM.V1.Api.Projects.iam_projects_service_accounts_create/3)

      assert {:ok, []} = BigQueryAdaptor.create_managed_service_accounts()
      assert BigQueryAdaptor.managed_service_accounts_enabled?() == false
    end

    test "update_iam_policy/0 should not update iam policy with service accounts" do
      pid = self()
      reject(&GoogleApi.IAM.V1.Api.Projects.iam_projects_service_accounts_list/3)
      reject(&GoogleApi.IAM.V1.Api.Projects.iam_projects_service_accounts_create/3)

      expect(
        GoogleApi.CloudResourceManager.V1.Api.Projects,
        :cloudresourcemanager_projects_set_iam_policy,
        fn _conn, _project_number, [body: body] ->
          send(pid, body.policy.bindings)
          {:ok, ""}
        end
      )

      BigQueryAdaptor.update_iam_policy()

      assert_received [_ | _] = bindings

      refute Enum.any?(bindings, fn binding ->
               Enum.any?(binding.members, fn member ->
                 member =~ "logflare-managed-"
               end)
             end)
    end
  end

  test "fetch iam policy for a given user" do
    user = insert(:user, bigquery_project_id: "my-project")

    expect(
      GoogleApi.CloudResourceManager.V1.Api.Projects,
      :cloudresourcemanager_projects_get_iam_policy,
      fn _, _project_id, [body: _body] ->
        policy = %Model.Policy{
          bindings: [
            %Model.Binding{members: ["user:original@user.com"], role: "roles/bigquery.jobUser"}
          ]
        }

        {:ok, policy}
      end
    )

    assert {:ok, policy} = BigQueryAdaptor.get_iam_policy(user)
    assert policy.bindings |> length() > 0
  end

  describe "fetch and update iam policy" do
    setup do
      original_pool_size =
        Application.get_env(:logflare, :bigquery_backend_adaptor)[
          :managed_service_account_pool_size
        ]

      Application.put_env(:logflare, :bigquery_backend_adaptor,
        managed_service_account_pool_size: 5
      )

      on_exit(fn ->
        Application.put_env(:logflare, :bigquery_backend_adaptor,
          managed_service_account_pool_size: original_pool_size
        )
      end)

      :ok
    end

    test "append_managed_sa_to_iam_policy/1 should update iam policy if it is missing managed service accounts" do
      user =
        insert(:user,
          bigquery_enable_managed_service_accounts: true,
          bigquery_project_id: "my-project"
        )

      expect(
        GoogleApi.CloudResourceManager.V1.Api.Projects,
        :cloudresourcemanager_projects_get_iam_policy,
        fn _, _project_id, [body: _body] ->
          policy = %Model.Policy{
            bindings: [
              %Model.Binding{members: ["user:original@user.com"], role: "roles/bigquery.jobUser"}
            ]
          }

          {:ok, policy}
        end
      )

      expect(
        GoogleApi.CloudResourceManager.V1.Api.Projects,
        :cloudresourcemanager_projects_set_iam_policy,
        fn _, _project_id, [body: body] ->
          {:ok, body.policy}
        end
      )

      expect(GoogleApi.IAM.V1.Api.Projects, :iam_projects_service_accounts_list, fn
        _conn, "projects/" <> _project_id, _opts ->
          {:ok,
           %{
             accounts: [
               %GoogleApi.IAM.V1.Model.ServiceAccount{
                 email: "logflare-managed-0@some-project.iam.gserviceaccount.com",
                 name:
                   "projects/some-project/serviceAccounts/logflare-managed-0@some-project.iam.gserviceaccount.com"
               }
             ],
             nextPageToken: nil
           }}
      end)

      assert {:ok, %Model.Policy{bindings: bindings}} =
               BigQueryAdaptor.append_managed_sa_to_iam_policy(user)

      members = Enum.flat_map(bindings, & &1.members)

      assert Enum.any?(members, fn member ->
               String.contains?(member, "user:original@user.com")
             end)

      assert Enum.any?(members, fn member ->
               String.contains?(member, "logflare-managed-")
             end)
    end

    test "append_managed_sa_to_iam_policy/1 should not update iam policy if it is missing managed service accounts" do
      user =
        insert(:user,
          bigquery_enable_managed_service_accounts: false,
          bigquery_project_id: "my-project"
        )

      reject(
        &GoogleApi.CloudResourceManager.V1.Api.Projects.cloudresourcemanager_projects_get_iam_policy/3
      )

      reject(
        &GoogleApi.CloudResourceManager.V1.Api.Projects.cloudresourcemanager_projects_set_iam_policy/3
      )

      assert {:error, :managed_service_accounts_disabled} =
               BigQueryAdaptor.append_managed_sa_to_iam_policy(user)
    end

    test "append_managed_sa_to_iam_policy/1 should not update iam policy if user does not have a project id" do
      user =
        insert(:user, bigquery_enable_managed_service_accounts: true, bigquery_project_id: nil)

      reject(
        &GoogleApi.CloudResourceManager.V1.Api.Projects.cloudresourcemanager_projects_get_iam_policy/3
      )

      reject(
        &GoogleApi.CloudResourceManager.V1.Api.Projects.cloudresourcemanager_projects_set_iam_policy/3
      )

      assert {:error, :no_project_id} = BigQueryAdaptor.append_managed_sa_to_iam_policy(user)
    end

    test "byob user should have managed service accounts appended to policy" do
      user =
        insert(:user,
          bigquery_project_id: "my-project",
          bigquery_enable_managed_service_accounts: true
        )

      pid = self()

      expect(
        GoogleApi.CloudResourceManager.V1.Api.Projects,
        :cloudresourcemanager_projects_set_iam_policy,
        fn _, _project_number, [body: body] ->
          send(pid, body.policy.bindings)
          {:ok, ""}
        end
      )

      expect(GoogleApi.IAM.V1.Api.Projects, :iam_projects_service_accounts_list, fn
        _conn, "projects/" <> _project_id, _opts ->
          {:ok,
           %{
             accounts: [
               %GoogleApi.IAM.V1.Model.ServiceAccount{
                 email: "logflare-managed-0@some-project.iam.gserviceaccount.com",
                 name:
                   "projects/some-project/serviceAccounts/logflare-managed-0@some-project.iam.gserviceaccount.com"
               }
             ],
             nextPageToken: nil
           }}
      end)

      policy = %Model.Policy{
        bindings: [
          %Model.Binding{members: ["user:some@user.com"], role: "roles/bigquery.jobUser"}
        ]
      }

      assert {:ok, _policy} =
               BigQueryAdaptor.append_managed_service_accounts(user.bigquery_project_id, policy)

      assert_received [_ | _] = bindings

      members = Enum.flat_map(bindings, & &1.members)

      assert Enum.any?(members, fn member ->
               String.contains?(member, "user:some@user.com")
             end)

      assert Enum.any?(members, fn member ->
               String.contains?(member, "logflare-managed-")
             end)
    end

    test "gen_utils get_conn/1 when managed sa pool is enabled and user has managed sa enabled" do
      pid = self()

      stub(Goth, :fetch, fn mod ->
        send(pid, mod)
        {:ok, %Goth.Token{token: "auth-token"}}
      end)

      user = insert(:user, bigquery_enable_managed_service_accounts: true)
      BigQueryAdaptor.get_conn({:query, user})
      assert_receive {Logflare.GothQuery, _, _}
    end

    test "gen_utils get_conn/1 when managed sa pool is enabled and user has managed sa disabled" do
      pid = self()

      stub(Goth, :fetch, fn mod ->
        send(pid, mod)
        {:ok, %Goth.Token{token: "auth-token"}}
      end)

      user =
        insert(:user,
          bigquery_project_id: "my-project",
          bigquery_enable_managed_service_accounts: false
        )

      BigQueryAdaptor.get_conn({:query, user})
      assert_receive {Logflare.Goth, _}
    end
  end

  test "gen_utils get_conn/1 when managed sa pool is disable and user has managed sa enabled" do
    pid = self()

    stub(Goth, :fetch, fn mod ->
      send(pid, mod)
      {:ok, %Goth.Token{token: "auth-token"}}
    end)

    user = insert(:user, bigquery_enable_managed_service_accounts: true)
    BigQueryAdaptor.get_conn({:query, user})
    assert_receive {Logflare.Goth, _}
  end

  test "gen_utils get_conn/1 when managed sa pool is disabled  and user has managed sa disabled" do
    pid = self()

    stub(Goth, :fetch, fn mod ->
      send(pid, mod)
      {:ok, %Goth.Token{token: "auth-token"}}
    end)

    user = insert(:user, bigquery_enable_managed_service_accounts: false)
    BigQueryAdaptor.get_conn({:query, user})
    assert_receive {Logflare.Goth, _}
  end
end
