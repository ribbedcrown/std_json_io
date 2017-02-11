defmodule StdJsonIo do

  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app)

    if !otp_app do
      raise "StdJsonIo requires an otp_app"
    end

    quote do
      use Supervisor
      @pool_name Module.concat(__MODULE__, Pool)
      @options Keyword.merge(unquote(opts), (Application.get_env(unquote(otp_app), __MODULE__) || []))


      def start_link(opts \\ []) do
        Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
      end

      def init(:ok) do
        pool_options = [
          name: {:local, @pool_name},
          worker_module: StdJsonIo.Worker,
          size: Keyword.get(@options, :pool_size, 5),
          max_overflow: Keyword.get(@options, :max_overflow, 10)
        ]

        script = Keyword.get(@options, :script)

        children = [:poolboy.child_spec(@pool_name, pool_options, [script: script])]

        files = Keyword.get(@options, :watch_files)

        children = add_reloader_spec_for_watched_files(children, files)

        supervise(children, strategy: :one_for_one, name: __MODULE__)
      end

      defp add_reloader_spec_for_watched_files(spec_list, nil), do: spec_list
      defp add_reloader_spec_for_watched_files(spec_list, []), do: spec_list
      defp add_reloader_spec_for_watched_files(spec_list, files) when is_list(files) do
        Application.ensure_started(:fs, :permanent)
        reloader_spec = worker(
          StdJsonIo.Reloader, [__MODULE__, Enum.map(files, &Path.expand/1)], []
        )
        [reloader_spec | spec_list]
      end


      def restart_io_workers! do
        case Process.whereis(@pool_name) do
          nil ->
            Supervisor.restart_child(__MODULE__, @pool_name)
          _pid ->
            Supervisor.terminate_child(__MODULE__, @pool_name)
            Supervisor.restart_child(__MODULE__, @pool_name)
        end
      end

      def json_call!(map, timeout \\ 10000) do
        case json_call(map, timeout) do
          {:ok, data} -> data
          {:error, reason } -> raise "Failed to call to json service #{__MODULE__} #{to_string(reason)}"
        end
      end

      def json_call(map, timeout \\ 10000) do
        result = :poolboy.transaction(@pool_name, fn worker ->
          GenServer.call(worker, {:json, map}, timeout)
        end)

        case result do
          {:ok, json} ->
            {:ok, data} = Poison.decode(json)
            if data["error"] do
              {:error, Map.get(data, "error")}
            else
              {:ok, data}
            end
          other -> other
        end
      end
    end
  end
end
