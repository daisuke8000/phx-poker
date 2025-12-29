defmodule PlanningPokerWeb.LobbyLive do
  @moduledoc """
  ロビー画面のLiveView。
  ルームの作成と参加を行う。
  """

  use PlanningPokerWeb, :live_view

  alias PlanningPoker.Rooms.{RoomServer, RoomSupervisor}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:room_id, "")
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("create_room", _params, socket) do
    case generate_unique_room_id() do
      {:ok, room_id} ->
        case RoomSupervisor.create_room(room_id) do
          {:ok, _} ->
            {:noreply, push_navigate(socket, to: ~p"/room/#{room_id}")}

          {:error, :too_many_rooms} ->
            {:noreply, assign(socket, :error, "サーバーが混雑しています。しばらくしてから再度お試しください")}

          {:error, _} ->
            {:noreply, assign(socket, :error, "ルームの作成に失敗しました")}
        end

      {:error, :max_retries} ->
        {:noreply, assign(socket, :error, "ルームIDの生成に失敗しました。再度お試しください")}
    end
  end

  @impl true
  def handle_event("join_room", %{"room_id" => room_id}, socket) do
    room_id = String.trim(room_id)

    if room_id == "" do
      {:noreply, assign(socket, :error, "ルームIDを入力してください")}
    else
      {:noreply, push_navigate(socket, to: ~p"/room/#{room_id}")}
    end
  end

  @impl true
  def handle_event("update_room_id", %{"room_id" => room_id}, socket) do
    # 英数字のみに制限し、大文字に変換
    sanitized =
      room_id
      |> String.replace(~r/[^a-zA-Z0-9]/, "")
      |> String.upcase()
      |> String.slice(0, 10)

    {:noreply,
     socket
     |> assign(:room_id, sanitized)
     |> assign(:error, nil)}
  end

  # Phase 1.2: ルームID衝突対策
  defp generate_unique_room_id(retries \\ 10)
  defp generate_unique_room_id(0), do: {:error, :max_retries}

  defp generate_unique_room_id(retries) do
    id = generate_room_id()

    if RoomServer.room_exists?(id) do
      generate_unique_room_id(retries - 1)
    else
      {:ok, id}
    end
  end

  defp generate_room_id do
    :crypto.strong_rand_bytes(4)
    |> Base.url_encode64(padding: false)
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.slice(0, 6)
    |> String.upcase()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-300 via-slate-200 to-slate-300 flex items-center justify-center p-4">
      <%!-- Background elements for glass effect --%>
      <div class="fixed inset-0 overflow-hidden pointer-events-none">
        <%!-- Gradient orbs --%>
        <div class="absolute top-20 left-10 w-72 h-72 bg-gradient-to-br from-slate-400/40 to-slate-500/30 rounded-full blur-2xl"></div>
        <div class="absolute top-40 right-20 w-80 h-80 bg-gradient-to-tl from-slate-500/35 to-slate-400/25 rounded-full blur-2xl"></div>
        <div class="absolute bottom-32 left-1/3 w-64 h-64 bg-gradient-to-tr from-slate-400/30 to-slate-300/40 rounded-full blur-2xl"></div>
        <div class="absolute -bottom-20 right-10 w-96 h-96 bg-gradient-to-bl from-slate-500/25 to-slate-400/35 rounded-full blur-2xl"></div>
        <%!-- Subtle geometric shapes --%>
        <div class="absolute top-1/4 right-1/4 w-32 h-32 bg-slate-400/20 rounded-3xl rotate-12 blur-xl"></div>
        <div class="absolute bottom-1/3 left-1/4 w-24 h-24 bg-slate-500/15 rounded-2xl -rotate-6 blur-xl"></div>
      </div>

      <div class="relative max-w-md w-full">
        <%!-- Hero Section --%>
        <div class="text-center mb-8">
          <h1 class="text-3xl font-semibold text-slate-700 mb-2 tracking-tight">
            Planning Poker
          </h1>
          <p class="text-slate-500">チームでストーリーポイントを見積もろう</p>
        </div>

        <%= if @error do %>
          <div class="bg-red-100/60 backdrop-blur-xl border border-red-300/40 text-red-700 px-4 py-3 rounded-2xl mb-6">
            <%= @error %>
          </div>
        <% end %>

        <%!-- Create Room Card (Glassmorphism) --%>
        <div class="bg-slate-50/40 backdrop-blur-xl rounded-3xl p-6 mb-4 shadow-xl shadow-slate-500/10 border border-slate-300/30">
          <h2 class="text-lg font-semibold text-slate-700 mb-1">新しいルームを作成</h2>
          <p class="text-slate-500 text-sm mb-4">ワンクリックでルームを作成</p>
          <form phx-submit="create_room">
            <button
              type="submit"
              class="w-full py-3 bg-slate-700/90 backdrop-blur-sm text-slate-100 font-medium rounded-2xl hover:bg-slate-600/90 transition-all duration-200 shadow-lg shadow-slate-700/20"
            >
              ルームを作成
            </button>
          </form>
        </div>

        <%!-- Divider --%>
        <div class="flex items-center gap-4 mb-4">
          <div class="flex-1 h-px bg-slate-400/30"></div>
          <span class="text-slate-500 text-sm">または</span>
          <div class="flex-1 h-px bg-slate-400/30"></div>
        </div>

        <%!-- Join Room Card (Glassmorphism) --%>
        <div class="bg-slate-50/40 backdrop-blur-xl rounded-3xl p-6 shadow-xl shadow-slate-500/10 border border-slate-300/30">
          <h2 class="text-lg font-semibold text-slate-700 mb-1">既存のルームに参加</h2>
          <p class="text-slate-500 text-sm mb-4">ルームIDを入力して参加</p>
          <form phx-submit="join_room" class="space-y-4">
            <div>
              <input
                type="text"
                name="room_id"
                value={@room_id}
                phx-change="update_room_id"
                placeholder="ルームID"
                class="w-full px-4 py-3 bg-slate-100/50 backdrop-blur-sm border border-slate-300/40 rounded-2xl text-slate-700 placeholder-slate-400 focus:outline-none focus:ring-2 focus:ring-slate-400/40 focus:border-slate-400/60 transition-all uppercase font-mono tracking-wider text-center"
                maxlength="10"
              />
            </div>
            <button
              type="submit"
              disabled={@room_id == ""}
              class={[
                "w-full py-3 font-medium rounded-2xl transition-all duration-200 border shadow-sm",
                @room_id != "" && "bg-slate-100/60 backdrop-blur-sm text-slate-600 border-slate-300/40 hover:bg-slate-100/80",
                @room_id == "" && "bg-slate-200/40 backdrop-blur-sm text-slate-400 border-slate-200/40 cursor-not-allowed"
              ]}
            >
              ルームに参加
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
