defmodule PlanningPokerWeb.HealthController do
  @moduledoc """
  Health check controller for Cloud Run.

  Cloud Run uses this endpoint to determine if the instance is healthy.
  Returns a simple "ok" text response with 200 status.
  """
  use PlanningPokerWeb, :controller

  def index(conn, _params) do
    text(conn, "ok")
  end
end
