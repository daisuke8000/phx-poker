defmodule PlanningPoker.Rooms.RoomSupervisor do
  @moduledoc """
  ルームサーバーを動的に生成・管理するDynamicSupervisor。

  各ルームは独立したGenServerプロセスとして動作し、
  クラッシュ時には自動的に再起動される。
  """

  use DynamicSupervisor

  alias PlanningPoker.Rooms.RoomServer

  # セキュリティ: リソース枯渇攻撃対策
  @max_rooms 1000

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  新しいルームを作成する。既に存在する場合は既存のルームを返す。
  最大#{@max_rooms}ルームまで作成可能。
  """
  def create_room(room_id) do
    case RoomServer.room_exists?(room_id) do
      true ->
        {:ok, :already_exists}

      false ->
        # セキュリティ: ルーム数上限チェック
        current_count = count_rooms()

        if current_count >= @max_rooms do
          {:error, :too_many_rooms}
        else
          child_spec = %{
            id: RoomServer,
            start: {RoomServer, :start_link, [room_id]},
            restart: :temporary
          }

          case DynamicSupervisor.start_child(__MODULE__, child_spec) do
            {:ok, _pid} -> {:ok, :created}
            {:error, {:already_started, _pid}} -> {:ok, :already_exists}
            error -> error
          end
        end
    end
  end

  @doc """
  ルームを終了する。
  """
  def stop_room(room_id) do
    case Registry.lookup(PlanningPoker.RoomRegistry, room_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  現在アクティブなルーム数を取得する。
  """
  def count_rooms do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  @doc """
  すべてのアクティブなルームIDを取得する。
  """
  def list_rooms do
    Registry.select(PlanningPoker.RoomRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
