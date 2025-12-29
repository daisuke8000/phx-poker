defmodule PlanningPoker.Rooms.RoomServer do
  @moduledoc """
  ルームの状態を管理するGenServer。

  1ルーム = 1プロセスで、PubSubを通じて状態変更を
  すべての接続クライアントにブロードキャストする。
  """

  use GenServer

  alias PlanningPoker.Rooms.Room

  @idle_timeout :timer.minutes(30)

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------

  @doc """
  ルームサーバーを起動する。
  """
  def start_link(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via_tuple(room_id))
  end

  @doc """
  ルームにプレイヤーを追加する。
  role は :player（デフォルト）または :spectator。
  """
  def join(room_id, user_id, name, role \\ :player) do
    GenServer.call(via_tuple(room_id), {:join, user_id, name, role})
  end

  @doc """
  プレイヤーがルームから退出する。
  """
  def leave(room_id, user_id) do
    GenServer.call(via_tuple(room_id), {:leave, user_id})
  end

  @doc """
  プレイヤーが投票する。
  """
  def vote(room_id, user_id, card) do
    GenServer.call(via_tuple(room_id), {:vote, user_id, card})
  end

  @doc """
  投票結果を公開する。
  """
  def reveal(room_id) do
    GenServer.call(via_tuple(room_id), :reveal)
  end

  @doc """
  投票をリセットする。
  """
  def reset(room_id) do
    GenServer.call(via_tuple(room_id), :reset)
  end

  @doc """
  トピック（見積もり対象）を設定する。
  """
  def set_topic(room_id, topic) do
    GenServer.call(via_tuple(room_id), {:set_topic, topic})
  end

  @doc """
  カードセットを変更する。
  """
  def set_cards(room_id, preset_name) do
    GenServer.call(via_tuple(room_id), {:set_cards, preset_name})
  end

  @doc """
  現在のルーム状態を取得する。
  """
  def get_state(room_id) do
    GenServer.call(via_tuple(room_id), :get_state)
  end

  @doc """
  ルームが存在するかどうかを確認する。
  """
  def room_exists?(room_id) do
    case Registry.lookup(PlanningPoker.RoomRegistry, room_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  # ----------------------------------------------------------------------------
  # Server Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(room_id) do
    room = Room.new(room_id)
    schedule_idle_check()
    {:ok, room}
  end

  @impl true
  def handle_call({:join, user_id, name, role}, {from_pid, _ref}, room) do
    # Phase 2.1: クライアントプロセスを監視（退出検知用）
    Process.monitor(from_pid)

    case Room.add_player(room, user_id, name, role, from_pid) do
      {:ok, updated_room} ->
        broadcast_update(updated_room)
        {:reply, {:ok, updated_room}, updated_room}

      {:error, :room_full} = error ->
        {:reply, error, room}
    end
  end

  @impl true
  def handle_call({:leave, user_id}, _from, room) do
    updated_room = Room.remove_player(room, user_id)
    broadcast_update(updated_room)

    # 全員退出したらプロセスを終了
    if map_size(updated_room.players) == 0 do
      {:stop, :normal, :ok, updated_room}
    else
      {:reply, :ok, updated_room}
    end
  end

  @impl true
  def handle_call({:vote, user_id, card}, _from, room) do
    # Phase 4.3: サーバーサイドレート制限チェック
    case Room.check_rate_limit(room, user_id) do
      {:error, :rate_limited} ->
        {:reply, {:error, :rate_limited}, room}

      {:ok, rate_limited_room} ->
        case Room.vote(rate_limited_room, user_id, card) do
          {:ok, updated_room} ->
            broadcast_update(updated_room)
            {:reply, {:ok, updated_room}, updated_room}

          {:error, reason} ->
            {:reply, {:error, reason}, rate_limited_room}
        end
    end
  end

  @impl true
  def handle_call(:reveal, _from, room) do
    updated_room = Room.reveal(room)
    broadcast_update(updated_room)
    {:reply, {:ok, updated_room}, updated_room}
  end

  @impl true
  def handle_call(:reset, _from, room) do
    updated_room = Room.reset(room)
    broadcast_update(updated_room)
    {:reply, {:ok, updated_room}, updated_room}
  end

  @impl true
  def handle_call({:set_topic, topic}, _from, room) do
    updated_room = Room.set_topic(room, topic)
    broadcast_update(updated_room)
    {:reply, {:ok, updated_room}, updated_room}
  end

  @impl true
  def handle_call({:set_cards, preset_name}, _from, room) do
    case Room.set_cards(room, preset_name) do
      {:ok, updated_room} ->
        broadcast_update(updated_room)
        {:reply, {:ok, updated_room}, updated_room}

      {:error, reason} ->
        {:reply, {:error, reason}, room}
    end
  end

  @impl true
  def handle_call(:get_state, _from, room) do
    {:reply, room, room}
  end

  @impl true
  def handle_info(:idle_check, room) do
    if map_size(room.players) == 0 do
      {:stop, :normal, room}
    else
      schedule_idle_check()
      {:noreply, room}
    end
  end

  # Phase 2.1: クライアントプロセス終了時の自動退出処理
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, room) do
    case Room.get_user_by_pid(room, pid) do
      nil ->
        # 該当するユーザーがいない場合は何もしない
        {:noreply, room}

      user_id ->
        # ユーザーを削除し、PIDマッピングもクリーンアップ
        updated_room =
          room
          |> Room.remove_player(user_id)
          |> Room.remove_pid(pid)

        broadcast_update(updated_room)

        # 全員退出したらプロセスを終了
        if map_size(updated_room.players) == 0 do
          {:stop, :normal, updated_room}
        else
          {:noreply, updated_room}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Private Functions
  # ----------------------------------------------------------------------------

  defp via_tuple(room_id) do
    {:via, Registry, {PlanningPoker.RoomRegistry, room_id}}
  end

  defp broadcast_update(room) do
    Phoenix.PubSub.broadcast(
      PlanningPoker.PubSub,
      "room:#{room.id}",
      {:room_updated, room}
    )
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_timeout)
  end
end
