defmodule K8sBroadcaster do
  @moduledoc """
  K8sBroadcaster keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @spec get_region() :: String.t()
  def get_region() do
    Application.fetch_env!(:k8s_broadcaster, :region)
  end
end
