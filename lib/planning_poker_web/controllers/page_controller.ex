defmodule PlanningPokerWeb.PageController do
  use PlanningPokerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
