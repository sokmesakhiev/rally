Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    if Rails.env.development?
      # The frontend's dev server port isn't fixed — @lovable.dev/vite-tanstack-config's
      # sandbox detection can pick something other than Vite's default 5173 (e.g. 8080).
      # Allow any localhost port locally rather than chasing specific numbers.
      origins(/\Ahttp:\/\/(localhost|127\.0\.0\.1):\d+\z/)
    else
      origins ENV.fetch("FRONTEND_URL", "http://localhost:3000"),
               "http://localhost:5173",
               "http://localhost:4173"
    end

    resource "*",
      headers: :any,
      methods: [ :get, :post, :patch, :put, :delete, :options, :head ],
      # Content-Disposition: browsers only expose a small default allowlist
      # of response headers to cross-origin JS (Content-Type, Content-Length,
      # etc.) — Content-Disposition isn't in it. Without this, fetch()-based
      # downloads (see api-client.ts's downloadFile, used by
      # registrationsApi.exportCsv) can never read the filename Rails'
      # send_data sets and always fall back to a generic one.
      expose: [ "Authorization", "Content-Disposition" ]
  end
end
