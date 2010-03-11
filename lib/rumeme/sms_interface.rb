require "net/http"
require "net/https"
require 'rubygems'
require 'nokogiri'

module Rumeme

  # This is the main class used to interface with the M4U SMS messaging server.
  class SmsInterface

    # allow_splitting, allow_long_messages, response_code, response_message, username, password, use_message_id, secure, http_connection, server_list, message_list,
    # http_proxy, http_proxy_port, http_proxy_auth, https_proxy, https_proxy_port, https_proxy_auth, text_buffer,

    # Constructor.
    #
    # The allowSplitting parameter determines whether messages over
    # 160 characters will be split over multiple SMSes or truncated.
    #
    # The allowLongMessages parameter enables messages longer than 160
    # characters to be sent as special concatenated messages. For this
    # to take effect, the allowSplitting parameter must be set to false.
    def initialize
      @username = Rumeme.configuration.username
      @password = Rumeme.configuration.password
      @use_message_id = Rumeme.configuration.use_message_id
      @secure = Rumeme.configuration.secure
      @long_messages_strategy = Rumeme.configuration.long_messages_strategy
      
      @response_code = -1
      @response_message = nil
      @message_list = []
      @http_connection = nil
      @http_proxy = nil
      @http_proxy_port = 80
      @http_proxy_auth = nil
      @https_proxy = nil
      @https_proxy_port = 443
      @https_proxy_auth = nil
      @text_buffer = nil
      @server_list = ["smsmaster.m4u.com.au", "smsmaster1.m4u.com.au", "smsmaster2.m4u.com.au"]
    end


    # Set the HTTP proxy server, if one is being used.
    # Also specify an optional proxy username and password.
    # only for php version
    def set_http_proxy proxy, port = 80, username = nil, password = nil
      @http_proxy, @http_proxy_port = proxy, port
      @http_proxy_username, @http_proxy_password = username, password
      @http_proxy_auth = Base64.encode64("#{username}:#{password}").chop unless username.nil? || password.nil?
      raise 'proxy is not supported'
    end

    # Set the HTTPS proxy server, if one is being used.
    # Also specify an optional proxy username and password.
    # only for php version
    def set_https_proxy proxy, port = 443, username = nil, password = nil
      @https_proxy, @https_proxy_port = proxy, port
      @https_proxy_auth = Base64.encode64("#{username}:#{password}").chop unless username.nil? || password.nil?
      raise 'proxy is not supported'
    end

    # Return the response code received from calls to
    # changePassword, getCreditsRemaining, sendMessages, and
    # checkReplies.
    attr_reader :response_code

    # Return the message that was returned with the response code.
    attr_reader :response_message

    # Add a message to be sent.
    def add_message args
      p 'in add_message '
      args[:phone_number] = strip_invalid(args[:phone_number]) #not good idea, modifying original args, from outer scope (antlypls)

      raise ArgumentError.new("phone_number is empty") if args[:phone_number].nil? || args[:phone_number].empty?
      raise ArgumentError.new("message is empty") if args[:message].nil? || args[:message].empty?

      messages = process_long_message(args[:message])
      @message_list.concat(messages.map{|m| SmsMessage.new(args.merge({:message => m}))})
    end

    # Clear all the messages from the list.
    def clear_messages
      @message_list.clear
    end

    # Open a connection to the specified server.
    # proxy is not supported
    def open_server_connection server, secure
      p "in open_server_connection: #{server} #{secure}"
      if secure
        @http_connection =  Net::HTTP.new(server, 443)
        @http_connection.use_ssl = true
      else
        @http_connection =  Net::HTTP.new(server, 80)
      end
    end

    def open_server_connection2 server, secure
      port, use_ssl = secure ? [443, true] : [80, false]

      http_connection =  Net::HTTP.new(server, port)
      http_connection.use_ssl = use_ssl
      http_connection
    end

    # 4 php api compatibility, returns response code from latest http flush
    def read_response_code
      @latest_response_code
    end

    # Change the password on the local machine and server.
    # not implemented
    def change_password
      raise 'Not Implemented'
    end

    # Return the list of replies we have received.
    def check_replies auto_confirm = true
      p 'in check_replies'

      response_message, response_code = post_data_to_server("CHECKREPLY2.0\r\n.\r\n")
      return if response_code != 150

      p response_message
      messages = response_message.split("\r\n")[1..-2].map{|message_line| SmsReply.parse(message_line, @use_message_id)}

      if auto_confirm && messages.size > 0
        confirm_replies_received
      end

      return messages
    end

    # sends confirmation to server
    def confirm_replies_received
      p 'in confirm_replies_received'
      post_data_to_server "CONFIRM_RECEIVED\r\n.\r\n"
    end

    # Returns the credits remaining (for prepaid users only).
    def get_credits_remaining
      p 'in get_credits_remaining'

      response_message, response_code = post_data_to_server("MESSAGES\r\n.\r\n")

      if response_message =~ /^(\d+)\s+OK\s+(\d+).+/
        if response_code != 100
          p 'M4U code is not 100'
          return -1
        end
        return $2.to_i
      else
        p "cant parse response: #{response_message}"
        return -1
      end
    end

    # Sends all the messages that have been added with the
    # add_message command.
    def send_messages
      text_buffer = "MESSAGES2.0\r\n"

      @message_list.each {|sm|
        s = "#{sm.message_id} #{sm.phone_number} #{sm.delay} #{sm.validity_period} "
        s << (sm.delivery_report ? "1 " : "0 ")
        s << "#{sm.message}\r\n"
        text_buffer << s
      }
      text_buffer << ".\r\n"

      response_message, response_code = post_data_to_server(text_buffer)

      return response_code == 100 ? true : false
    end

    private

    def process_long_message message
      return [message] if message.length <= 160
      case @long_messages_strategy
        when :send
          [message]
        when :cut
          [message[0..160]]
        when :split
          SmsInterface.split_message message
        else
          raise 'unknown long_messages_strategy'
      end
    end

    def self.split_message message
      messages = split_message_internal message
      i = 1
      ["#{messages[0]}...(1/#{messages.size})"].concat(messages[1..-1].map {|m| "(#{i+=1}/#{messages.size})#{m}"})
    end

    def self.split_message_internal message
      list =[]

      head, message = head_tail_split(message, 152)
      list << head

      while !message.nil? do
        head, message = head_tail_split(message, 155)
        list << head
      end

      list
    end

    def self.head_tail_split message, max_len
      return [message, nil] if message.length < max_len
      pattern = /\s\.,!;:-\)/
      index = message[0..max_len].rindex(pattern) || max_len
      [message[0..index], message[index+1 .. -1]]
    end

    # Strip invalid characters from the phone number.
    def strip_invalid phone
      return if phone.nil?
      "+#{phone.gsub(/[^0-9]/, '')}"
    end

    # Connect to the M4U server
    def connect
      p 'in connect'
      return unless @http_connection.nil?

      @server_list.all? {|server| !open_server_connection(server, @secure)} # unusefull code open_server_connection,
                                                                            # does not connect to server, just creates http object,
                                                                            # so we can't check availability of the server at this moment (antlypls)

      @text_buffer = "m4u\r\nUSER=#{@username}"
      if @use_message_id
        @text_buffer << "#"
      end
      @text_buffer << "\r\nPASSWORD=#{@password}\r\nVER=PHP1.0\r\n"
    end

    # only for php compatibility, just free object reference
    def close
      @http_connection = nil
    end

    # Flush the text buffer to the HTTP connection.
=begin

    def flush_buffer
      p 'in flush_buffer'
      p "buffer: #{@text_buffer}"
      headers = {
              'Content-Length' => @text_buffer.length.to_s
      }

      path = '/'

      begin
        resp, data = @http_connection.post(path, @text_buffer, headers)
        p resp.inspect
        p data.inspect
      rescue
        p "error: #{$!}"
        return false
      end

      if resp.code.to_i != 200
        p 'http response code != 200'
        return false
      end

      @latest_response_code = @response_code = resp.code.to_i

      doc = Nokogiri::HTML(data)

      return false if doc.xpath('//title').text != "M4U SMSMASTER"

      @response_message = @latest_response = doc.xpath('//body').text.strip
      if @response_message =~ /^(\d+)\s+/
        @latest_response_code = @response_code = $1.to_i
      end

      p "latest response code: #{ @latest_response_code}"
      p "response #{@response_message.inspect}"

      @text_buffer = ''
      return true
    end

=end

    def post_data_to_server data
      p 'post_data_to_server'
      #connect
      #flush
      #close

      http_connection = open_server_connection2(@server_list[0], @secure)

      text_buffer = "m4u\r\nUSER=#{@username}"
      if @use_message_id
        text_buffer << "#"
      end
      text_buffer << "\r\nPASSWORD=#{@password}\r\nVER=PHP1.0\r\n"

      text_buffer << data

      p "buffer: #{text_buffer}"
      headers = {
              'Content-Length' => text_buffer.length.to_s
      }

      path = '/'

      begin
        resp, data = http_connection.post(path, text_buffer, headers)
        p resp.inspect
        p data.inspect
      rescue
        p "error: #{$!}"
        return false
      end

      if resp.code.to_i != 200
        p 'http response code != 200'
        return false
      end

      @latest_response_code = @response_code = resp.code.to_i

      doc = Nokogiri::HTML(data)

      return false if doc.xpath('//title').text != "M4U SMSMASTER"

      @response_message = @latest_response = doc.xpath('//body').text.strip
      if @response_message =~ /^(\d+)\s+/
        @latest_response_code = @response_code = $1.to_i
      end

      p "latest response code: #{ @latest_response_code}"
      p "response #{@response_message.inspect}"

      [@response_message, @response_code]
    end
  end
end