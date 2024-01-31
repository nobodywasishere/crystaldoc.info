module CrystalDoc::Bot
  macro register(cmd, &block)
    %handle = Tourmaline::CommandHandler.new({{ cmd }}) do |ctx|
      Log.info { "Message from #{ctx.message.try &.chat.id}"}
      next unless ctx.message.try &.chat.id == telegram_user_id
      {{ block.body }}
    rescue ex
      ctx.reply("Exception: #{ex.inspect}")
    end

    client.register(%handle)
  end

  def self.poll
    return unless (telegram_api_key = ::Config.telegram_api_key) && (telegram_user_id = ::Config.telegram_user_id)

    client = Tourmaline::Client.new(telegram_api_key)

    register("add") do |ctx|
      url = ctx.text.to_s
      next if url.empty?

      response = if CrystalDoc::Queries.repo_exists(REPO_DB, url)
                   "Repository exists"
                 else
                   vcs = CrystalDoc::VCS.new(url)
                   vcs.parse(REPO_DB)
                 end

      ctx.reply(response)
    end

    register("regenerate_all") do |ctx|
      count = CrystalDoc::Queries.regenerate_all_docs(REPO_DB)
      ctx.reply("Added #{count} doc jobs to queue.")
    end

    client.poll
  end
end
