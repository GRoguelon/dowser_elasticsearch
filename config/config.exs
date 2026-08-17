import Config

config :dowser_client,
  http_adapter: Dowser.Client.HTTP.Req,
  json_adapter: Dowser.Client.JSON.Jason
