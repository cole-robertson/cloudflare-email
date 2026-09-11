namespace :cloudflare do
  namespace :email do
    desc "Inspect routing without changes (ADDRESS=addr [WORKER_NAME=name] [ACCOUNT_ID=id]); nonzero if failed or unverified"
    task check_route: :environment do
      require "cloudflare/email/check_route_task"
      exit Cloudflare::Email::CheckRouteTask.call(
        address: ENV["ADDRESS"], worker_name: ENV["WORKER_NAME"] || ENV["WORKER"], account_id: ENV["ACCOUNT_ID"],
      )
    end
  end
end
