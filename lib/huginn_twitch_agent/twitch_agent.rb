module Agents
  class TwitchAgent < Agent
    include FormConfigurable
    can_dry_run!
    no_bulk_receive!
    default_schedule "never"

    description do
      <<-MD
      The Twitch Agent is able to find information about users, checking live stream, others.

      `debug` is used for verbose mode.

      `user_id` is the id of the user.

      `client_secret` is the secret of your app.

      `access_token` is token created for your app.

      `client_id` is the id of your app.

      `type` is for the wanted action like get_user_informations/active_streams.

      `expected_receive_period_in_days` is used to determine if the Agent is working. Set it to the maximum number of days
      that you anticipate passing without this Agent receiving an incoming Event.
      MD
    end

    event_description <<-MD
      Events look like this:

          {
            "data": [
              {
                "id": "187039841",
                "login": "xtivalia",
                "display_name": "xTivalia",
                "type": "",
                "broadcaster_type": "affiliate",
                "description": "Streameuse multigaming de 24ans, joueuse PC depuis 9 ans. Chill, bonne humeur et fun uniquement. ",
                "profile_image_url": "https://static-cdn.jtvnw.net/jtv_user_pictures/1deae406-248d-40e0-9775-5e67da5eafd9-profile_image-300x300.png",
                "offline_image_url": "https://static-cdn.jtvnw.net/jtv_user_pictures/f7b1b1da-f573-4c01-b9e2-f8c9d84c08cc-channel_offline_image-1920x1080.jpeg",
                "view_count": 1227,
                "created_at": "2017-12-23T18:56:07Z"
              }
            ]
          }
    MD

    def default_options
      {
        'user_id' => '',
        'client_id' => '{% credential twitch_client_id %}',
        'client_secret' => '{% credential twitch_client_secret %}',
        'access_token' => '{% credential twitch_access_token %}',
        'debug' => 'false',
        'emit_events' => 'false',
        'expected_receive_period_in_days' => '2',
      }
    end

    form_configurable :user_id, type: :string
    form_configurable :client_id, type: :string
    form_configurable :client_secret, type: :string
    form_configurable :access_token, type: :string
    form_configurable :debug, type: :boolean
    form_configurable :emit_events, type: :boolean
    form_configurable :expected_receive_period_in_days, type: :string
    form_configurable :type, type: :array, values: ['get_user_informations', 'active_streams']
    def validate_options
      errors.add(:base, "type has invalid value: should be 'get_user_informations', 'active_streams'") if interpolated['type'].present? && !%w(get_user_informations active_streams).include?(interpolated['type'])

      unless options['user_id'].present?
        errors.add(:base, "user_id is a required field")
      end

      unless options['client_id'].present?
        errors.add(:base, "client_id is a required field")
      end

      unless options['client_secret'].present?
        errors.add(:base, "client_secret is a required field")
      end

      unless options['access_token'].present?
        errors.add(:base, "access_token is a required field")
      end

      if options.has_key?('emit_events') && boolify(options['emit_events']).nil?
        errors.add(:base, "if provided, emit_events must be true or false")
      end

      if options.has_key?('debug') && boolify(options['debug']).nil?
        errors.add(:base, "if provided, debug must be true or false")
      end

      unless options['expected_receive_period_in_days'].present? && options['expected_receive_period_in_days'].to_i > 0
        errors.add(:base, "Please provide 'expected_receive_period_in_days' to indicate how many days can pass before this Agent is considered to be not working")
      end
    end

    def working?
      event_created_within?(options['expected_receive_period_in_days']) && !recent_error_logs?
    end

    def receive(incoming_events)
      incoming_events.each do |event|
        interpolate_with(event) do
          log event
          trigger_action
        end
      end
    end

    def check
      trigger_action
    end

    private

    def set_credential(name, value)
      c = user.user_credentials.find_or_initialize_by(credential_name: name)
      c.credential_value = value
      c.save!
    end

    def log_curl_output(code,body)

      log "request status : #{code}"

      if interpolated['debug'] == 'true'
        log "body"
        log body
      end

    end

    def token_refresh()

      uri = URI.parse("https://id.twitch.tv/oauth2/token?&client_id=#{interpolated['client_id']}&client_secret=#{interpolated['client_secret']}&grant_type=client_credentials")
      request = Net::HTTP::Post.new(uri)

      req_options = {
        use_ssl: uri.scheme == "https",
      }

      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      log_curl_output(response.code,response.body)

      payload = JSON.parse(response.body)
      if interpolated['access_token'] != payload['access_token']
        set_credential("twitch_access_token", payload['access_token'])
        if interpolated['debug'] == 'true'
          log "twitch_access_token credential updated"
        end
      end
      current_timestamp = Time.now.to_i
      memory['expires_at'] = payload['expires_in'] + current_timestamp

    end

    def check_token_validity()

      if memory['expires_at'].nil?
        token_refresh()
      else
        timestamp_to_compare = memory['expires_at']
        current_timestamp = Time.now.to_i
        difference_in_hours = (timestamp_to_compare - current_timestamp) / 3600.0
        if difference_in_hours < 2
          token_refresh()
        else
          log "refresh not needed"
        end
      end
    end

    def active_streams()

      check_token_validity()
      uri = URI.parse("https://api.twitch.tv/helix/streams?user_id=#{interpolated['user_id']}")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{interpolated['access_token']}"
      request["Client-Id"] = "#{interpolated['client_id']}"

      req_options = {
        use_ssl: uri.scheme == "https",
      }

      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      if interpolated['debug'] == 'true'
        log "response.body"
        log response.body
      end

      log "request status : #{response.code}"
      payload = JSON.parse(response.body)
      if payload != memory['last_status']
        if "#{memory['last_status']}" == ''
          payload['data'].each do |stream|
             log_curl_output(response.code,stream)
          end
        else
          last_status = memory['last_status']
          last_status = JSON.parse(last_status)
          payload['data'].each do |stream|
            found = false
            if interpolated['debug'] == 'true'
              log "stream"
              log stream
            end
            last_status['data'].each do |streambis|
              if stream['started_at'] == streambis['started_at']
                found = true
              end
              if interpolated['debug'] == 'true'
                log "streambis"
                log streambis
                log "found is #{found}!"
              end
            end
            if found == false
              log_curl_output(response.code,stream)
            end
          end
        end
        memory['last_status'] = payload
      end
    end

    def get_user_informations()

      check_token_validity()
      uri = URI.parse("https://api.twitch.tv/helix/users?id=#{interpolated['user_id']}")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{interpolated['access_token']}"
      request["Client-Id"] = "#{interpolated['client_id']}"
      
      req_options = {
        use_ssl: uri.scheme == "https",
      }

      response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(request)
      end

      log_curl_output(response.code,response.body)

      payload = JSON.parse(response.body)

      if payload != memory['last_status']
        if interpolated['emit_events'] == 'true'
          create_event payload: payload
        end
        memory['last_status'] = payload
      else
        if interpolated['debug'] == 'true'
          log "no diff"
        end
      end
    end

    def trigger_action

      case interpolated['type']
      when "get_user_informations"
        get_user_informations()
      when "active_streams"
        active_streams()
      else
        log "Error: type has an invalid value (#{interpolated['type']})"
      end
    end
  end
end
