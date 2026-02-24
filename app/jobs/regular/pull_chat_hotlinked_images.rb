# frozen_string_literal: true

module Jobs
  class PullChatHotlinkedImages < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(args)
      return unless SiteSetting.download_remote_images_to_local?
      return unless SiteSetting.chat_hotlink_images_enabled

      @chat_message_id = args[:chat_message_id]
      raise Discourse::InvalidParameters.new(:chat_message_id) if @chat_message_id.blank?

      if Jobs.run_immediately?
        pull_hotlinked_images
      else
        DistributedMutex.synchronize(
          "pull_chat_hotlinked_images_#{@chat_message_id}",
          validity: 2.minutes,
        ) { pull_hotlinked_images }
      end
    end

    private

    def pull_hotlinked_images
      message = ::Chat::Message.find_by(id: @chat_message_id)
      return if message.nil?
      return if message.chat_channel.nil?
      return if message.trashed?

      downloaded_uploads = {}
      raw = message.message

      extract_images_from(message.cooked).each do |node|
        src = node["src"] || node["href"]
        next if src.blank?

        download_src = src
        download_src = "#{SiteSetting.force_https ? "https" : "http"}:#{src}" if src.start_with?("//")

        next unless should_download_image?(download_src)

        normalized_src = normalize_src(src)
        next if downloaded_uploads.key?(normalized_src)

        begin
          upload = attempt_download(download_src, message.user_id)
          next unless upload&.persisted?

          downloaded_uploads[normalized_src] = upload

          unless message.upload_ids.include?(upload.id)
            UploadReference.ensure_exist!(upload_ids: [upload.id], target: message)
          end
        rescue StandardError => e
          log(:error, "Failed to download hotlinked image #{download_src}: #{e.message}")
        end
      end

      return if downloaded_uploads.empty?

      raw = replace_hotlinked_urls(raw, downloaded_uploads)

      if raw != message.message
        message.message = raw
        message.cook
        message.save!

        ::Chat::Publisher.publish_refresh!(message.chat_channel, message)
      end
    end

    def extract_images_from(html)
      doc = Nokogiri::HTML5.fragment(html)
      doc.css("img[src], a.lightbox[href]") - doc.css("img.avatar, img.emoji, .lightbox img[src]")
    end

    def should_download_image?(src)
      return false if src.blank?

      local_bases = [
        Discourse.base_url,
        Discourse.asset_host,
        SiteSetting.external_emoji_url.presence,
      ].compact

      local_bases.each do |base|
        return false if src.start_with?(base)
      end

      return false if src =~ %r{\A/[^/]}i

      return false if Discourse.store.has_been_uploaded?(src)

      begin
        uri = URI.parse(src)
      rescue URI::Error
        return false
      end

      return false unless uri.hostname

      SiteSetting.should_download_images?(src)
    end

    def attempt_download(src, user_id)
      src = Upload.signed_url_from_secure_uploads_url(src) if Upload.secure_uploads_url?(src)

      downloaded = download(src)
      return nil unless downloaded

      if File.size(downloaded.path) > SiteSetting.max_image_size_kb.kilobytes
        log(:info, "Image too large: #{src}")
        return nil
      end

      filename = File.basename(URI.parse(src).path)
      filename << File.extname(downloaded.path) unless filename.include?(".")

      upload = UploadCreator.new(downloaded, filename, origin: src).create_for(user_id)

      unless upload.persisted?
        log(:info, "Failed to create upload for #{src}: #{upload.errors.full_messages.join(", ")}")
        return nil
      end

      upload
    end

    def download(src)
      downloaded = nil
      retries = 3

      begin
        downloaded =
          FileHelper.download(
            src,
            max_file_size: SiteSetting.max_image_size_kb.kilobytes,
            retain_on_max_file_size_exceeded: true,
            tmp_file_name: "discourse-chat-hotlinked",
            follow_redirect: true,
            read_timeout: 15,
          )
      rescue StandardError => e
        log(:warn, "Download error for #{src}: #{e.message}")
        if (retries -= 1) > 0 && !Rails.env.test?
          sleep 1
          retry
        end
      end

      downloaded
    end

    def replace_hotlinked_urls(raw, downloaded_uploads)
      InlineUploads.replace_hotlinked_image_urls(raw: raw) do |match_src|
        normalized_match = normalize_src(match_src)
        downloaded_uploads[normalized_match]
      end
    end

    def normalize_src(src)
      uri = Addressable::URI.heuristic_parse(src)
      uri.normalize!
      uri.scheme = nil
      uri.to_s
    rescue URI::Error, Addressable::URI::InvalidURIError
      src
    end

    def log(level, message)
      Rails.logger.public_send(
        level,
        "#{RailsMultisite::ConnectionManagement.current_db}: [ChatHotlinkImages] #{message}",
      )
    end
  end
end
