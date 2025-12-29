defmodule PlanningPokerWeb.PageControllerTest do
  use PlanningPokerWeb.ConnCase

  test "GET / shows lobby page", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Planning Poker"
  end
end
