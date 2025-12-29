defmodule PlanningPoker.Rooms.Room do
  @moduledoc """
  ルームの状態を表す構造体。

  ## フィールド
  - `id` - ルームの一意識別子
  - `name` - ルーム名
  - `players` - 参加者マップ %{user_id => %{name: "Alice", vote: nil}}
  - `pids` - 参加者PIDマップ %{pid => user_id}（退出検知用）
  - `rate_limits` - レート制限用タイムスタンプ %{user_id => [timestamps]}
  - `revealed` - 投票結果が公開されているか
  - `cards` - 使用可能なカードのリスト
  - `cards_preset` - 現在のカードプリセット名（:fibonacci, :tshirt など）
  - `history` - 過去の投票履歴（直近10件）
  - `topic` - 現在の見積もり対象（ストーリー/タスク名）
  """

  @type role :: :player | :spectator
  @type player :: %{name: String.t(), vote: String.t() | integer() | nil, role: role()}
  @type history_entry :: %{
          timestamp: DateTime.t(),
          topic: String.t() | nil,
          cards_preset: atom(),
          votes: list(%{name: String.t(), vote: String.t() | integer()}),
          stats: map() | nil
        }
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          players: %{String.t() => player()},
          pids: %{pid() => String.t()},
          rate_limits: %{String.t() => list(integer())},
          revealed: boolean(),
          cards: list(String.t() | integer()),
          cards_preset: atom(),
          history: list(history_entry()),
          topic: String.t() | nil
        }

  @max_history 10
  @max_players 20

  # 事前定義されたカードセット
  @card_presets %{
    fibonacci: [1, 2, 3, 5, 8, 13, 21, "?"],
    modified_fibonacci: [0, 1, 2, 3, 5, 8, 13, 21, 34, "?"],
    tshirt: ["XS", "S", "M", "L", "XL", "XXL", "?"],
    simple: [1, 2, 3, 4, 5, "?"],
    powers_of_2: [1, 2, 4, 8, 16, 32, "?"]
  }

  def card_presets, do: @card_presets

  defstruct [
    :id,
    :name,
    players: %{},
    pids: %{},
    rate_limits: %{},
    revealed: false,
    cards: [1, 2, 3, 5, 8, 13, 21, "?"],
    cards_preset: :fibonacci,
    history: [],
    topic: nil
  ]

  @doc """
  新しいルームを作成する。
  """
  def new(id, name \\ nil) do
    %__MODULE__{
      id: id,
      name: name || "Room #{id}"
    }
  end

  @doc """
  トピック（見積もり対象）を設定する。
  """
  def set_topic(%__MODULE__{} = room, topic) do
    %{room | topic: topic}
  end

  @doc """
  カードセットを変更する。
  preset_name は :fibonacci, :modified_fibonacci, :tshirt, :simple, :powers_of_2 のいずれか。
  変更時に全員の投票をリセットする（既存投票が新カードセットに存在しない問題を防止）。
  """
  def set_cards(%__MODULE__{} = room, preset_name) when is_atom(preset_name) do
    case Map.get(@card_presets, preset_name) do
      nil ->
        {:error, :invalid_preset}

      cards ->
        # Phase 3.1: カードセット変更時に全員の投票をクリア
        reset_players =
          room.players
          |> Enum.map(fn {id, player} -> {id, %{player | vote: nil}} end)
          |> Map.new()

        {:ok, %{room | cards: cards, cards_preset: preset_name, players: reset_players}}
    end
  end

  @doc """
  プレイヤーをルームに追加する。
  role は :player（デフォルト）または :spectator。
  最大#{@max_players}人まで参加可能。
  pid はプロセス監視用（退出検知）。
  """
  def add_player(room, user_id, name, role \\ :player, pid \\ nil)

  def add_player(%__MODULE__{players: players} = _room, _user_id, _name, _role, _pid)
      when map_size(players) >= @max_players do
    {:error, :room_full}
  end

  def add_player(%__MODULE__{} = room, user_id, name, role, pid) do
    player = %{name: name, vote: nil, role: role}
    updated_room = %{room | players: Map.put(room.players, user_id, player)}

    # PIDが指定されていればマッピングを追加
    updated_room =
      if pid do
        %{updated_room | pids: Map.put(updated_room.pids, pid, user_id)}
      else
        updated_room
      end

    {:ok, updated_room}
  end

  @doc """
  PIDからユーザーIDを取得する。
  """
  def get_user_by_pid(%__MODULE__{pids: pids}, pid) do
    Map.get(pids, pid)
  end

  @doc """
  PIDマッピングを削除する。
  """
  def remove_pid(%__MODULE__{} = room, pid) do
    %{room | pids: Map.delete(room.pids, pid)}
  end

  # Phase 4.3: サーバーサイドレート制限
  @rate_limit_window_ms 10_000  # 10秒
  @rate_limit_max_events 20     # 10秒間で最大20イベント

  @doc """
  レート制限をチェックし、許可された場合は更新されたルームを返す。
  """
  def check_rate_limit(%__MODULE__{rate_limits: rate_limits} = room, user_id) do
    now = System.monotonic_time(:millisecond)
    user_events = Map.get(rate_limits, user_id, [])

    # ウィンドウ内のイベントのみフィルタリング
    recent_events = Enum.filter(user_events, &(&1 > now - @rate_limit_window_ms))

    if length(recent_events) >= @rate_limit_max_events do
      {:error, :rate_limited}
    else
      # 新しいイベントを追加
      updated_events = [now | recent_events]
      updated_limits = Map.put(rate_limits, user_id, updated_events)
      {:ok, %{room | rate_limits: updated_limits}}
    end
  end

  @doc """
  プレイヤーをルームから削除する。
  """
  def remove_player(%__MODULE__{} = room, user_id) do
    %{room | players: Map.delete(room.players, user_id)}
  end

  @doc """
  プレイヤーの投票を記録する。
  """
  def vote(%__MODULE__{} = room, user_id, card) do
    case Map.get(room.players, user_id) do
      nil ->
        {:error, :player_not_found}

      player ->
        updated_player = %{player | vote: card}
        {:ok, %{room | players: Map.put(room.players, user_id, updated_player)}}
    end
  end

  @doc """
  投票結果を公開する。
  """
  def reveal(%__MODULE__{} = room) do
    %{room | revealed: true}
  end

  @doc """
  投票をリセットする（新しいラウンドを開始）。
  公開済みの場合は履歴に保存する。
  """
  def reset(%__MODULE__{revealed: true} = room) do
    history_entry = create_history_entry(room)
    updated_history = [history_entry | room.history] |> Enum.take(@max_history)

    reset_players =
      room.players
      |> Enum.map(fn {id, player} -> {id, %{player | vote: nil}} end)
      |> Map.new()

    %{room | players: reset_players, revealed: false, history: updated_history, topic: nil}
  end

  def reset(%__MODULE__{revealed: false} = room) do
    reset_players =
      room.players
      |> Enum.map(fn {id, player} -> {id, %{player | vote: nil}} end)
      |> Map.new()

    %{room | players: reset_players, revealed: false, topic: nil}
  end

  defp create_history_entry(%__MODULE__{} = room) do
    votes =
      room.players
      |> Enum.map(fn {_id, player} -> %{name: player.name, vote: player.vote} end)
      |> Enum.filter(fn v -> v.vote != nil end)

    %{
      timestamp: DateTime.utc_now(),
      topic: room.topic,
      cards_preset: room.cards_preset,
      votes: votes,
      stats: vote_stats(room)
    }
  end

  @doc """
  全員が投票したかどうかを確認する（観戦者を除く）。
  """
  def all_voted?(%__MODULE__{players: players}) do
    player_only =
      players
      |> Enum.filter(fn {_id, player} -> player.role == :player end)

    case player_only do
      [] -> false
      _ -> Enum.all?(player_only, fn {_id, player} -> player.vote != nil end)
    end
  end

  @doc """
  投票の統計情報を計算する。
  """
  def vote_stats(%__MODULE__{revealed: false}), do: nil

  def vote_stats(%__MODULE__{players: players, revealed: true}) do
    # 観戦者を除外してプレイヤーのみで統計
    player_only =
      players
      |> Enum.filter(fn {_id, player} -> player.role == :player end)

    votes =
      player_only
      |> Enum.map(fn {_id, player} -> player.vote end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == "?"))

    numeric_votes = Enum.filter(votes, &is_integer/1)

    %{
      total_votes: length(player_only),
      votes_cast: length(votes),
      average: calculate_average(numeric_votes),
      min: if(numeric_votes != [], do: Enum.min(numeric_votes), else: nil),
      max: if(numeric_votes != [], do: Enum.max(numeric_votes), else: nil)
    }
  end

  defp calculate_average([]), do: nil
  defp calculate_average(votes), do: Float.round(Enum.sum(votes) / length(votes), 1)
end
