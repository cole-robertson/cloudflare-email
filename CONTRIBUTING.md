# Contributing

## Ruby and Rails

```sh
bundle install
bundle exec rake test
bundle exec ruby script/verify_package.rb
```

The package check builds both gems and boots consumer apps against the packaged
files, including Mailbox Kit without Cloudflare. CI also covers supported
Ruby/Rails combinations, SQLite tenancy, and PostgreSQL concurrency.

## Cloudflare Worker

Use Node 22.12+:

```sh
cd templates/worker
npm ci
npm test
npm run check
```

After changing shared Worker files, sync the standalone deployment template from
the repository root:

```sh
node script/sync_deploy_template.mjs
node script/sync_deploy_template.mjs --check
```

## Local receiving integration

With the Worker dependencies installed:

```sh
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle exec ruby script/verify_local_ingress.rb
```

This uses synthetic mail, temporary Rails storage, and local workerd.

## Documentation

Keep setup examples focused on the current release. Put API details in focused
guides and keep historical plans and verification evidence in `maintainer/`.
The standalone Deploy to Cloudflare directory must work when copied out of this
repository; its shared domain guide uses absolute links for that reason.
