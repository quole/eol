class ResourceValidation
  @queue = 'data'

  # Everything is a class method, here; no instances.
  class << self
    def perform(current_user_id, content_partner_id, resource_id, port)
      log("START user ##{current_user_id} resource ##{resource_id} port #{port}")
      partner = ContentPartner.find(content_partner_id, include: {resources: :resource_status })
      log("Content Partner: #{partner.display_name}")
      resource = partner.resources.find(resource_id)
      log("Resource: #{resource.title}")
      resource.upload_resource_to_content_master!(port)
      write_log_send_mail(current_user_id, resource_id)
    end

    def write_log_send_mail(user_id, resource_id)
      activity = CuratorActivityLog.create!(user_id: user_id, changeable_object_type_id: ChangeableObjectType.resource_validation.id,
             target_id: resource_id, activity: Activity.resource_validation)
      PendingNotification.create!(user_id: user_id, notification_frequency_id: NotificationFrequency.immediately.id, target: activity, reason: 'auto_email_after_validation')
      Resque.enqueue(PrepareAndSendNotifications)
    end

    def log(msg)
      Rails.logger.error("++ ResourceValidation: #{msg}")
    end
  end

end
