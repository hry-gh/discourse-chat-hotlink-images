# frozen_string_literal: true

# name: discourse-chat-hotlink-images
# about: Automatically downloads and rehosts hotlinked images in chat messages
# meta_topic_id: TODO
# version: 0.1.0
# authors: Discourse
# url: https://github.com/discourse/discourse-chat-hotlink-images
# required_version: 2.7.0

enabled_site_setting :chat_hotlink_images_enabled

module ::ChatHotlinkImages
  PLUGIN_NAME = "discourse-chat-hotlink-images"
end

require_relative "lib/chat_hotlink_images/engine"

after_initialize do
  # Only run if chat plugin is enabled
  if defined?(Chat)
    # When a chat message is processed (after oneboxes, etc.), enqueue job to pull hotlinked images
    # This fires after Jobs::Chat::ProcessMessage runs, so cooked HTML has proper <img> tags
    on(:chat_message_processed) do |doc, message|
      if SiteSetting.chat_hotlink_images_enabled && SiteSetting.download_remote_images_to_local?
        Jobs.enqueue(
          :pull_chat_hotlinked_images,
          chat_message_id: message.id,
        )
      end
    end
  end
end
