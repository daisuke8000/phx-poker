defmodule PlanningPokerWeb.RoomLive do
  @moduledoc """
  ルーム画面のLiveView。
  プランニングポーカーのメインゲーム画面。
  """

  use PlanningPokerWeb, :live_view

  alias PlanningPoker.Rooms.{Room, RoomServer, RoomSupervisor}
  alias PlanningPokerWeb.Presence

  @impl true
  def mount(%{"id" => room_id}, _session, socket) do
    # URLパラメータから名前を取得（なければnil）
    raw_name = get_connect_params(socket)["name"]
    # セキュリティ: 入力サニタイズ（mountの時点ではまだsanitize_name未定義のため直接処理）
    sanitized_name =
      if is_binary(raw_name) do
        raw_name
        |> String.trim()
        |> String.slice(0, 30)
        |> String.replace(~r/[\x00-\x1f]/, "")
      else
        ""
      end

    has_name = sanitized_name != ""
    user_id = generate_user_id()

    socket =
      socket
      |> assign(:room_id, room_id)
      |> assign(:user_id, user_id)
      |> assign(:input_name, "")
      |> assign(:player_name, sanitized_name)
      |> assign(:room, Room.new(room_id))
      |> assign(:selected_card, nil)
      |> assign(:presence, %{})
      |> assign(:joined, false)
      |> assign(:role, :player)

    if connected?(socket) do
      # ルームが存在しなければ作成
      case RoomSupervisor.create_room(room_id) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :too_many_rooms} ->
          # ルーム数上限到達時は作成せず閲覧のみ
          :ok
        _ -> :ok
      end

      # PubSubをサブスクライブ
      Phoenix.PubSub.subscribe(PlanningPoker.PubSub, "room:#{room_id}")

      if has_name do
        # 名前があれば自動的に参加
        case RoomServer.join(room_id, user_id, sanitized_name) do
          {:ok, room} ->
            {:ok, _} =
              Presence.track(self(), "room:#{room_id}", user_id, %{
                name: sanitized_name,
                joined_at: System.system_time(:second)
              })

            {:ok,
             socket
             |> assign(:room, room)
             |> assign(:joined, true)
             |> assign(:presence, Presence.list("room:#{room_id}"))}

          {:error, :room_full} ->
            room = RoomServer.get_state(room_id)
            {:ok,
             socket
             |> assign(:room, room)
             |> put_flash(:error, "ルームが満員です（最大20人）")}

          {:error, _} ->
            room = RoomServer.get_state(room_id)
            {:ok, assign(socket, :room, room)}
        end
      else
        # 名前がなければモーダル表示（joined: false のまま）
        room = RoomServer.get_state(room_id)
        {:ok, assign(socket, :room, room)}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    name = params["name"]

    if name && String.trim(name) != "" do
      {:noreply, assign(socket, :player_name, name)}
    else
      {:noreply, socket}
    end
  end

  # 入室イベント（モーダルから）
  @impl true
  def handle_event("join_room", %{"name" => name, "role" => role_str}, socket) do
    # セキュリティ: 入力サニタイズ
    sanitized_name = sanitize_name(name)
    role = if role_str == "spectator", do: :spectator, else: :player

    if sanitized_name == "" do
      {:noreply, put_flash(socket, :error, "名前を入力してください")}
    else
      room_id = socket.assigns.room_id
      user_id = socket.assigns.user_id

      case RoomServer.join(room_id, user_id, sanitized_name, role) do
        {:ok, room} ->
          {:ok, _} =
            Presence.track(self(), "room:#{room_id}", user_id, %{
              name: sanitized_name,
              role: role,
              joined_at: System.system_time(:second)
            })

          {:noreply,
           socket
           |> assign(:player_name, sanitized_name)
           |> assign(:role, role)
           |> assign(:room, room)
           |> assign(:joined, true)
           |> assign(:presence, Presence.list("room:#{room_id}"))}

        {:error, :room_full} ->
          {:noreply, put_flash(socket, :error, "ルームが満員です（最大20人）")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "参加に失敗しました")}
      end
    end
  end

  @impl true
  def handle_event("update_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :input_name, name)}
  end

  @impl true
  def handle_event("select_card", %{"card" => card}, socket) do
    card_value = parse_card(card)
    room_id = socket.assigns.room_id
    user_id = socket.assigns.user_id

    {:ok, _room} = RoomServer.vote(room_id, user_id, card_value)
    {:noreply, assign(socket, :selected_card, card_value)}
  end

  @impl true
  def handle_event("reveal", _params, socket) do
    {:ok, _room} = RoomServer.reveal(socket.assigns.room_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:ok, _room} = RoomServer.reset(socket.assigns.room_id)
    {:noreply, assign(socket, :selected_card, nil)}
  end

  @impl true
  def handle_event("set_topic", %{"topic" => topic}, socket) do
    # セキュリティ: 入力サニタイズ
    sanitized_topic = sanitize_topic(topic)
    {:ok, _room} = RoomServer.set_topic(socket.assigns.room_id, sanitized_topic)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_cards", %{"preset" => preset_str}, socket) do
    # セキュリティ: ホワイトリストで検証してからアトムに変換
    valid_presets = Room.card_presets() |> Map.keys() |> Enum.map(&Atom.to_string/1)

    if preset_str in valid_presets do
      preset_atom = String.to_existing_atom(preset_str)
      {:ok, _room} = RoomServer.set_cards(socket.assigns.room_id, preset_atom)
      {:noreply, assign(socket, :selected_card, nil)}
    else
      # 無効な入力は無視（悪意ある入力対策）
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("copy_link", _params, socket) do
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: room_url(socket)})}
  end

  @impl true
  def handle_event("copy_results", _params, socket) do
    room = socket.assigns.room
    markdown = format_results_markdown(room)
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: markdown})}
  end

  @impl true
  def handle_event("copy_history", %{"index" => index_str}, socket) do
    # セキュリティ: 安全な整数パース（不正入力でクラッシュ防止）
    case Integer.parse(index_str) do
      {index, ""} when index >= 0 ->
        entry = Enum.at(socket.assigns.room.history, index)

        if entry do
          markdown = format_history_entry_markdown(entry)
          {:noreply, push_event(socket, "copy_to_clipboard", %{text: markdown})}
        else
          {:noreply, socket}
        end

      _ ->
        # 無効なインデックスは無視
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:room_updated, room}, socket) do
    {:noreply, assign(socket, :room, room)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    presence = Presence.list("room:#{socket.assigns.room_id}")
    {:noreply, assign(socket, :presence, presence)}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:room_id] && socket.assigns[:user_id] && socket.assigns[:joined] do
      RoomServer.leave(socket.assigns.room_id, socket.assigns.user_id)
    end

    :ok
  end

  defp generate_user_id do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
  end

  # セキュリティ: 入力サニタイズ関数
  @max_name_length 30
  @max_topic_length 100

  defp sanitize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.slice(0, @max_name_length)
    |> String.replace(~r/[\x00-\x1f]/, "")  # 制御文字を除去
  end

  defp sanitize_name(_), do: ""

  defp sanitize_topic(nil), do: nil

  defp sanitize_topic(topic) when is_binary(topic) do
    sanitized =
      topic
      |> String.trim()
      |> String.slice(0, @max_topic_length)
      |> String.replace(~r/[\x00-\x1f]/, "")  # 制御文字を除去

    if sanitized == "", do: nil, else: sanitized
  end

  defp sanitize_topic(_), do: nil

  defp parse_card(card) do
    case Integer.parse(card) do
      {int, ""} -> int
      _ -> card
    end
  end

  defp room_url(socket) do
    "#{PlanningPokerWeb.Endpoint.url()}/room/#{socket.assigns.room_id}"
  end

  defp get_initial(name) do
    name
    |> String.trim()
    |> String.first()
    |> String.upcase()
  end

  defp format_timestamp(datetime) do
    # UTCで表示（+9時間して日本時間に近似）
    jst_hour = rem(datetime.hour + 9, 24)
    "#{String.pad_leading(Integer.to_string(jst_hour), 2, "0")}:#{String.pad_leading(Integer.to_string(datetime.minute), 2, "0")}"
  end

  defp format_results_markdown(room) do
    stats = Room.vote_stats(room)
    topic_line = if room.topic, do: "## #{room.topic}\n\n", else: ""

    votes_lines =
      room.players
      |> Enum.filter(fn {_, p} -> p.role == :player end)
      |> Enum.map(fn {_, p} -> "- #{p.name}: #{p.vote || "-"}" end)
      |> Enum.join("\n")

    stats_line =
      if stats do
        "\n\n**平均: #{stats.average || "-"}** (最小: #{stats.min || "-"}, 最大: #{stats.max || "-"})"
      else
        ""
      end

    "#{topic_line}### 投票結果\n\n#{votes_lines}#{stats_line}"
  end

  defp format_history_entry_markdown(entry) do
    topic_line = if entry.topic, do: "## #{entry.topic}\n\n", else: ""

    votes_lines =
      entry.votes
      |> Enum.map(fn v -> "- #{v.name}: #{v.vote}" end)
      |> Enum.join("\n")

    stats_line =
      if entry.stats do
        "\n\n**平均: #{entry.stats.average || "-"}** (最小: #{entry.stats.min || "-"}, 最大: #{entry.stats.max || "-"})"
      else
        ""
      end

    "#{topic_line}### 投票結果\n\n#{votes_lines}#{stats_line}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-300 via-slate-200 to-slate-300">
      <%!-- Background elements for glass effect --%>
      <div class="fixed inset-0 overflow-hidden pointer-events-none">
        <%!-- Gradient orbs --%>
        <div class="absolute top-10 left-20 w-80 h-80 bg-gradient-to-br from-slate-400/40 to-slate-500/30 rounded-full blur-2xl"></div>
        <div class="absolute top-1/3 right-10 w-72 h-72 bg-gradient-to-tl from-slate-500/35 to-slate-400/25 rounded-full blur-2xl"></div>
        <div class="absolute bottom-20 left-10 w-64 h-64 bg-gradient-to-tr from-slate-400/30 to-slate-300/40 rounded-full blur-2xl"></div>
        <div class="absolute bottom-1/4 right-1/3 w-96 h-96 bg-gradient-to-bl from-slate-500/25 to-slate-400/35 rounded-full blur-2xl"></div>
        <%!-- Subtle geometric shapes --%>
        <div class="absolute top-1/2 left-1/4 w-40 h-40 bg-slate-400/20 rounded-3xl rotate-45 blur-xl"></div>
        <div class="absolute top-20 right-1/3 w-28 h-28 bg-slate-500/15 rounded-2xl -rotate-12 blur-xl"></div>
      </div>

      <%= if !@joined do %>
        <%!-- Join Modal (Glassmorphism) --%>
        <div class="fixed inset-0 flex items-center justify-center p-4 z-50 bg-slate-400/20 backdrop-blur-sm">
          <div class="bg-slate-50/50 backdrop-blur-xl rounded-3xl p-8 w-full max-w-md shadow-2xl shadow-slate-500/20 border border-slate-300/30">
            <div class="text-center mb-6">
              <h2 class="text-xl font-semibold text-slate-700 mb-1">ルームに参加</h2>
              <p class="text-slate-500">ルームID: <span class="font-mono text-slate-600"><%= @room_id %></span></p>
            </div>

            <form phx-submit="join_room" class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-slate-600 mb-2">あなたの名前</label>
                <input
                  type="text"
                  name="name"
                  value={@input_name}
                  phx-change="update_name"
                  placeholder="名前を入力"
                  autofocus
                  class="w-full px-4 py-3 bg-slate-100/50 backdrop-blur-sm border border-slate-300/40 rounded-2xl text-slate-700 placeholder-slate-400 focus:outline-none focus:ring-2 focus:ring-slate-400/40 focus:border-slate-400/60 transition-all"
                  maxlength="20"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-slate-600 mb-2">参加タイプ</label>
                <div class="flex gap-3">
                  <label class="flex-1 cursor-pointer">
                    <input type="radio" name="role" value="player" checked class="peer sr-only" />
                    <div class="p-3 bg-slate-100/50 backdrop-blur-sm border border-slate-300/40 rounded-2xl text-center transition-all peer-checked:bg-slate-700/90 peer-checked:text-slate-100 peer-checked:border-slate-700">
                      <div class="text-sm font-medium">プレイヤー</div>
                      <div class="text-xs opacity-70 mt-1">投票に参加</div>
                    </div>
                  </label>
                  <label class="flex-1 cursor-pointer">
                    <input type="radio" name="role" value="spectator" class="peer sr-only" />
                    <div class="p-3 bg-slate-100/50 backdrop-blur-sm border border-slate-300/40 rounded-2xl text-center transition-all peer-checked:bg-slate-700/90 peer-checked:text-slate-100 peer-checked:border-slate-700">
                      <div class="text-sm font-medium">観戦</div>
                      <div class="text-xs opacity-70 mt-1">結果を見る</div>
                    </div>
                  </label>
                </div>
              </div>
              <button
                type="submit"
                disabled={String.trim(@input_name) == ""}
                class={[
                  "w-full py-3 font-medium rounded-2xl transition-all duration-200 shadow-lg",
                  String.trim(@input_name) != "" && "bg-slate-700/90 backdrop-blur-sm text-slate-100 hover:bg-slate-600/90 shadow-slate-700/20",
                  String.trim(@input_name) == "" && "bg-slate-400/60 backdrop-blur-sm text-slate-200 cursor-not-allowed shadow-slate-400/10"
                ]}
              >
                参加する
              </button>
            </form>

            <a href="/" class="block text-center mt-5 text-slate-400 hover:text-slate-600 transition-colors text-sm">
              ← ロビーに戻る
            </a>
          </div>
        </div>
      <% else %>
        <%!-- Game Room Header (Glassmorphism) --%>
        <header class="relative bg-slate-50/50 backdrop-blur-xl border-b border-slate-300/30 shadow-sm">
          <div class="max-w-5xl mx-auto px-4 py-3 flex items-center justify-between">
            <div class="flex items-center gap-4">
              <a href="/" class="text-slate-400 hover:text-slate-600 transition-colors text-sm">
                ← ロビー
              </a>
              <div class="h-5 w-px bg-slate-400/30"></div>
              <h1 class="font-medium text-slate-600">
                Room: <span class="font-mono text-slate-700"><%= @room_id %></span>
              </h1>
            </div>
            <div class="flex items-center gap-4">
              <% player_count = Enum.count(@room.players, fn {_, p} -> p.role == :player end) %>
              <% spectator_count = Enum.count(@room.players, fn {_, p} -> p.role == :spectator end) %>
              <span class="text-slate-500 text-sm">
                <span class="font-medium text-slate-600"><%= player_count %></span> プレイヤー
                <%= if spectator_count > 0 do %>
                  <span class="text-slate-400">・</span>
                  <span class="font-medium text-slate-500"><%= spectator_count %></span> 観戦
                <% end %>
              </span>
              <button
                phx-click="copy_link"
                id="copy-link-btn"
                phx-hook="CopyToClipboard"
                class="px-3 py-1.5 text-slate-600 rounded-xl bg-slate-100/50 hover:bg-slate-200/60 backdrop-blur-sm border border-slate-300/30 transition-all duration-200 text-sm"
              >
                リンクをコピー
              </button>
            </div>
          </div>
        </header>

        <main class="relative max-w-5xl mx-auto px-4 py-6">
          <%!-- Current Round Topic (Glassmorphism) --%>
          <div class="bg-slate-50/40 backdrop-blur-xl rounded-3xl p-4 mb-6 shadow-xl shadow-slate-500/10 border border-slate-300/30">
            <form phx-change="set_topic" class="flex items-center gap-3">
              <label class="text-sm font-medium text-slate-500 whitespace-nowrap">このラウンド:</label>
              <input
                type="text"
                name="topic"
                value={@room.topic || ""}
                placeholder="見積もり対象のストーリー / タスク名..."
                class="flex-1 px-4 py-2 bg-slate-100/50 backdrop-blur-sm border border-slate-300/40 rounded-xl text-slate-700 placeholder-slate-400 focus:outline-none focus:ring-2 focus:ring-slate-400/40 focus:border-slate-400/60 transition-all text-sm"
                maxlength="100"
                phx-debounce="500"
              />
            </form>
          </div>

          <%!-- Players Grid (Glassmorphism) --%>
          <div class="bg-slate-50/40 backdrop-blur-xl rounded-3xl p-5 mb-6 shadow-xl shadow-slate-500/10 border border-slate-300/30">
            <h2 class="text-sm font-medium text-slate-500 mb-4">参加者</h2>
            <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-3">
              <%= for {player_id, player} <- @room.players do %>
                <div class={[
                  "relative p-3 rounded-2xl text-center transition-all duration-200 backdrop-blur-sm",
                  player_id == @user_id && "ring-2 ring-slate-400/50 ring-offset-2 ring-offset-transparent",
                  player.role == :spectator && "bg-slate-100/30 border border-slate-200/30 opacity-80",
                  player.role == :player && player.vote && "bg-slate-200/50 border border-slate-300/40",
                  player.role == :player && !player.vote && "bg-slate-100/40 border border-slate-200/40"
                ]}>
                  <%!-- Avatar --%>
                  <div class={[
                    "w-10 h-10 mx-auto mb-2 rounded-full flex items-center justify-center text-sm font-bold transition-all duration-200",
                    player.role == :spectator && "bg-slate-400/40 text-slate-500",
                    player.role == :player && player.vote && "bg-slate-600/90 text-slate-100",
                    player.role == :player && !player.vote && "bg-slate-300/60 text-slate-500"
                  ]}>
                    <%= if player.role == :player && player.vote && @room.revealed do %>
                      <span class="text-lg"><%= player.vote %></span>
                    <% else %>
                      <%= get_initial(player.name) %>
                    <% end %>
                  </div>

                  <%!-- Status Badge (for players) --%>
                  <%= if player.role == :player && player.vote && !@room.revealed do %>
                    <div class="absolute -top-1 -right-1 w-5 h-5 bg-slate-500/90 rounded-full flex items-center justify-center shadow-sm">
                      <span class="text-slate-100 text-xs">✓</span>
                    </div>
                  <% end %>

                  <%!-- Spectator Badge --%>
                  <%= if player.role == :spectator do %>
                    <div class="absolute -top-1 -right-1 px-1.5 py-0.5 bg-slate-400/80 rounded-full flex items-center justify-center shadow-sm">
                      <span class="text-slate-100 text-[10px]">観戦</span>
                    </div>
                  <% end %>

                  <div class="text-sm font-medium text-slate-600 truncate">
                    <%= player.name %>
                  </div>
                  <%= if player_id == @user_id do %>
                    <div class="text-xs text-slate-400 mt-0.5">あなた</div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Vote Stats (Glassmorphism) --%>
          <%= if @room.revealed do %>
            <% stats = Room.vote_stats(@room) %>
            <%= if stats do %>
              <div class="bg-slate-50/40 backdrop-blur-xl rounded-3xl p-5 mb-6 shadow-xl shadow-slate-500/10 border border-slate-300/30">
                <div class="flex items-center justify-between mb-4">
                  <h2 class="text-sm font-medium text-slate-500">投票結果</h2>
                  <button
                    phx-click="copy_results"
                    class="px-2 py-1 text-xs text-slate-500 rounded-lg bg-slate-100/50 hover:bg-slate-200/60 backdrop-blur-sm border border-slate-300/30 transition-all duration-200"
                  >
                    コピー
                  </button>
                </div>
                <div class="grid grid-cols-4 gap-3">
                  <div class="text-center p-3 bg-slate-100/50 backdrop-blur-sm rounded-2xl border border-slate-300/30">
                    <div class="text-2xl font-bold text-slate-700"><%= stats.average || "-" %></div>
                    <div class="text-xs text-slate-500 mt-1">平均</div>
                  </div>
                  <div class="text-center p-3 bg-slate-100/50 backdrop-blur-sm rounded-2xl border border-slate-300/30">
                    <div class="text-2xl font-bold text-slate-600"><%= stats.min || "-" %></div>
                    <div class="text-xs text-slate-500 mt-1">最小</div>
                  </div>
                  <div class="text-center p-3 bg-slate-100/50 backdrop-blur-sm rounded-2xl border border-slate-300/30">
                    <div class="text-2xl font-bold text-slate-600"><%= stats.max || "-" %></div>
                    <div class="text-xs text-slate-500 mt-1">最大</div>
                  </div>
                  <div class="text-center p-3 bg-slate-100/50 backdrop-blur-sm rounded-2xl border border-slate-300/30">
                    <div class="text-2xl font-bold text-slate-500"><%= stats.votes_cast %>/<%= stats.total_votes %></div>
                    <div class="text-xs text-slate-500 mt-1">投票数</div>
                  </div>
                </div>
              </div>
            <% end %>
          <% end %>

          <%!-- Card Selection (Glassmorphism) - プレイヤーのみ表示 --%>
          <%= if @role == :player do %>
            <div class="bg-slate-50/40 backdrop-blur-xl rounded-3xl p-5 mb-6 shadow-xl shadow-slate-500/10 border border-slate-300/30">
              <div class="flex items-center justify-between mb-4">
                <h2 class="text-sm font-medium text-slate-500">カードを選択</h2>
                <form phx-change="set_cards">
                  <select
                    name="preset"
                    class="text-xs px-2 py-1 bg-slate-100/50 backdrop-blur-sm border border-slate-300/40 rounded-lg text-slate-600 focus:outline-none focus:ring-2 focus:ring-slate-400/40"
                  >
                    <option value="fibonacci" selected={@room.cards == [1, 2, 3, 5, 8, 13, 21, "?"]}>フィボナッチ</option>
                    <option value="modified_fibonacci" selected={@room.cards == [0, 1, 2, 3, 5, 8, 13, 21, 34, "?"]}>拡張フィボナッチ</option>
                    <option value="tshirt" selected={@room.cards == ["XS", "S", "M", "L", "XL", "XXL", "?"]}>Tシャツサイズ</option>
                    <option value="simple" selected={@room.cards == [1, 2, 3, 4, 5, "?"]}>シンプル (1-5)</option>
                    <option value="powers_of_2" selected={@room.cards == [1, 2, 4, 8, 16, 32, "?"]}>2の累乗</option>
                  </select>
                </form>
              </div>
              <div class="flex flex-wrap justify-center gap-2">
                <%= for card <- @room.cards do %>
                  <button
                    phx-click="select_card"
                    phx-value-card={card}
                    phx-throttle="300"
                    disabled={@room.revealed}
                    class={[
                      "w-14 h-20 rounded-2xl text-xl font-bold transition-all duration-200",
                      "border-2 focus:outline-none backdrop-blur-sm",
                      @selected_card == card && "bg-slate-700/90 text-slate-100 border-slate-700 scale-110 shadow-lg shadow-slate-700/30 -translate-y-1",
                      @selected_card != card && !@room.revealed && "bg-slate-100/50 text-slate-600 border-slate-300/40 hover:border-slate-400/60 hover:bg-slate-100/70 hover:scale-105",
                      @room.revealed && "opacity-40 cursor-not-allowed bg-slate-200/30 text-slate-400 border-slate-300/20"
                    ]}
                  >
                    <%= card %>
                  </button>
                <% end %>
              </div>
            </div>
          <% else %>
            <%!-- 観戦者向けメッセージ --%>
            <div class="bg-slate-50/40 backdrop-blur-xl rounded-3xl p-5 mb-6 shadow-xl shadow-slate-500/10 border border-slate-300/30">
              <div class="text-center text-slate-500">
                <span class="text-2xl">👁</span>
                <p class="mt-2 text-sm">観戦モードで参加中</p>
              </div>
            </div>
          <% end %>

          <%!-- Action Buttons (Glassmorphism) --%>
          <div class="flex justify-center gap-3">
            <%= if @room.revealed do %>
              <button
                phx-click="reset"
                phx-throttle="500"
                class="px-8 py-3 bg-slate-100/60 backdrop-blur-sm text-slate-600 font-medium rounded-2xl hover:bg-slate-100/80 transition-all duration-200 border border-slate-300/40 shadow-sm"
              >
                次のラウンド
              </button>
            <% else %>
              <button
                phx-click="reveal"
                phx-throttle="500"
                class="px-8 py-3 bg-slate-700/90 backdrop-blur-sm text-slate-100 font-medium rounded-2xl hover:bg-slate-600/90 transition-all duration-200 shadow-lg shadow-slate-700/20"
              >
                カードを開く
              </button>
            <% end %>
          </div>

          <%!-- History (Glassmorphism) --%>
          <%= if length(@room.history) > 0 do %>
            <div class="bg-slate-50/40 backdrop-blur-xl rounded-3xl p-5 mt-6 shadow-xl shadow-slate-500/10 border border-slate-300/30">
              <h2 class="text-sm font-medium text-slate-500 mb-4">履歴（直近10件）</h2>
              <div class="space-y-3">
                <%= for {entry, index} <- Enum.with_index(@room.history) do %>
                  <div class="bg-slate-100/50 backdrop-blur-sm rounded-2xl p-4 border border-slate-300/30">
                    <div class="flex items-center justify-between mb-2">
                      <div class="flex items-center gap-2">
                        <span class="text-xs text-slate-400">
                          #<%= length(@room.history) - index %>
                        </span>
                        <%= if entry.topic do %>
                          <span class="text-sm font-medium text-slate-600 truncate max-w-xs">
                            <%= entry.topic %>
                          </span>
                        <% end %>
                      </div>
                      <div class="flex items-center gap-2">
                        <button
                          phx-click="copy_history"
                          phx-value-index={index}
                          class="px-1.5 py-0.5 text-[10px] text-slate-400 rounded bg-slate-200/50 hover:bg-slate-300/50 transition-all duration-200"
                        >
                          コピー
                        </button>
                        <span class="text-xs text-slate-400">
                          <%= format_timestamp(entry.timestamp) %>
                        </span>
                      </div>
                    </div>
                    <div class="flex flex-wrap gap-2 mb-2">
                      <%= for vote_entry <- entry.votes do %>
                        <div class="flex items-center gap-1 bg-slate-200/50 rounded-lg px-2 py-1">
                          <span class="text-xs text-slate-500"><%= vote_entry.name %></span>
                          <span class="text-sm font-bold text-slate-700"><%= vote_entry.vote %></span>
                        </div>
                      <% end %>
                    </div>
                    <%= if entry.stats do %>
                      <div class="flex gap-4 text-xs text-slate-500">
                        <span>平均: <span class="font-medium text-slate-600"><%= entry.stats.average || "-" %></span></span>
                        <span>最小: <span class="font-medium text-slate-600"><%= entry.stats.min || "-" %></span></span>
                        <span>最大: <span class="font-medium text-slate-600"><%= entry.stats.max || "-" %></span></span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </main>
      <% end %>
    </div>
    """
  end
end
