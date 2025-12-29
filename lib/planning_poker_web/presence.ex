defmodule PlanningPokerWeb.Presence do
  @moduledoc """
  ルーム参加者のプレゼンス（在席状況）を管理する。

  Phoenix.Presenceを使用して、接続中のユーザーをリアルタイムで追跡する。
  """

  use Phoenix.Presence,
    otp_app: :planning_poker,
    pubsub_server: PlanningPoker.PubSub
end
