defmodule SleeperPlayerApiWeb.DefaultController do
  use SleeperPlayerApiWeb, :controller

  action_fallback SleeperPlayerApiWeb.FallbackController

  def index(conn, _params) do
    send_resp(conn, 200, "OK")
  end
end