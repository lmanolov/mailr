# Copyright (c) 2005, Benjamin Stiglitz
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
# 
# Modifications (c) 2005  by littlegreen
# 
require 'net/imap'

Net::IMAP.debug = true if CDF::CONFIG[:debug_imap]

class Net::IMAP
  class PlainAuthenticator
    def process(data)
      return "\0#{@user}\0#{@password}"
    end
    
    private 
    def initialize(user, password)
      @user = user
      @password = password
    end
  end
  add_authenticator('PLAIN', PlainAuthenticator)

  class Address
    def to_s
      if(name)
        "#{name} #{mailbox}@#{host}"
      else
        "#{mailbox}@#{host}"
      end
    end
  end
end

class AuthenticationError < RuntimeError
end

class IMAPMailbox
  attr_reader :connected
  attr_accessor :selected_mailbox
  cattr_accessor :logger
  
  def initialize
    @selected_mailbox = ''
    @folders          = {}
    @connected = false
  end
  
  def connect(username, password)
    unless @connected
      use_ssl = CDF::CONFIG[:imap_use_ssl] ? true : false
      port    = CDF::CONFIG[:imap_port] || (use_ssl ? 993 : 143)
      begin
        @imap   = Net::IMAP.new(CDF::CONFIG[:imap_server], port, use_ssl)
      rescue Net::IMAP::ByeResponseError => bye
        # make a timeout and retry
        begin
          System.sleep(CDF::CONFIG[:imap_bye_timeout_retry_seconds])
          @imap   = Net::IMAP.new(CDF::CONFIG[:imap_server], port, use_ssl)
        rescue Error => ex
          logger.error "Error on authentication!"
      	  logger.error bye.backtrace.join("\n")
          raise AuthenticationError.new
        end  
      rescue Net::IMAP::NoResponseError => noresp
        logger.error "Error on authentication!"
      	logger.error noresp.backtrace.join("\n")
        raise AuthenticationError.new
      rescue Net::IMAP::BadResponseError => bad
        logger.error "Error on authentication!"
      	logger.error bad.backtrace.join("\n")
        raise AuthenticationError.new
      rescue Net::IMAP::ResponseError => resp
        logger.error "Error on authentication!"
      	logger.error resp.backtrace.join("\n")
        raise AuthenticationError.new
      end  
      @username = username
      begin
      	logger.error "IMAP authentication - #{CDF::CONFIG[:imap_auth]}."
        if CDF::CONFIG[:imap_auth] == 'NOAUTH'
          @imap.login(username, password)
        else
          @imap.authenticate(CDF::CONFIG[:imap_auth], username, password)
        end
        @connected = true
      rescue Exception => ex
        logger.error "Error on authentication!"
      	logger.error ex.backtrace.join("\n")
        raise AuthenticationError.new
      end
    end
  end
  
  def imap
    @imap
  end
  
  # Function chnage password works only if root has run imap_backend
  # and users courier-authlib utility authtest - from courier-imap version 4.0.1
  def change_password(username, password, new_password)
    ret = ""
    cin, cout, cerr = Open3.popen3("/usr/sbin/authtest #{username} #{password} #{new_password}")
    ret << cerr.gets
    if ret.include?("Password change succeeded.")
      return true
    else
      logger.error "[!] Error on change password! - #{ret}" 
      return false
    end  
  end
  
  def disconnect
    if @connected
      @imap.logout
      #@imap.disconnect
      @imap = nil
      @connected = false
    end	
  end
  
  def [](mailboxname)
    @last_folder = IMAPFolderList.new(self, @username)[mailboxname]
  end
  
  def folders
    # reference just to stop GC
    @folder_list ||= IMAPFolderList.new(self, @username)
    @folder_list
  end
  
  def reload
    @folder_list.reload if @folder_list
  end
  
  def create_folder(name)
#     begin
    @imap.create(Net::IMAP.encode_utf7(name))
    reload
#     rescue Exception=>e
#     end
  end
  
  def delete_folder(name)
    begin
      @imap.delete(folders[name].utf7_name)
      reload
    rescue Exception=>e
      logger.error("Exception on delete #{name} folder #{e}") 
    end
  end
  
  def message_sent(message)
    # ensure we have sent folder
    begin
      @imap.create(CDF::CONFIG[:mail_sent])
    rescue Exception=>e
    end
    begin
      @imap.append(CDF::CONFIG[:mail_sent], message)  
      folders[CDF::CONFIG[:mail_sent]].cached = false if folders[CDF::CONFIG[:mail_sent]]
    rescue Exception=>e
      logger.error("Error on append  - #{e}") 
    end
      
  end
  
  def message_bulk(message)
    # ensure we have sent folder
    begin
      @imap.create(CDF::CONFIG[:mail_bulk_sent])
    rescue Exception=>e
    end
    begin
      @imap.append(CDF::CONFIG[:mail_bulk_sent], message)  
      folders[CDF::CONFIG[:mail_sent]].cached = false if folders[CDF::CONFIG[:mail_bulk_sent]]
    rescue Exception=>e
      logger.error("Error on bulk -  #{e}") 
    end  
  end
end

class IMAPFolderList
  include Enumerable
  cattr_accessor :logger
	
  def initialize(mailbox, username)
    @mailbox = mailbox
    @folders = Hash.new
    @username = username
  end
  
  def each
    refresh if @folders.empty?
    #@folders.each_value { |folder| yield folder }
    # We want to allow sorted access; for now only (FIXME)

    @folders.sort.each { |pair| yield pair.last }
  end
  
  def reload
    refresh
  end
  
  def [](name)
    refresh if @folders.empty?
    @folders[name]
  end

  private
  def refresh
    @folders = {}
    result = @mailbox.imap.list('', '*')
    if result 
      result.each do |info|
        folder = IMAPFolder.new(@mailbox, info.name, @username, info.attr, info.delim)
        @folders[folder.name] = folder
      end
    else
      # if there are no folders subscribe to INBOX - this is on first use
      @mailbox.imap.subscribe(CDF::CONFIG[:mail_inbox])
      # try again to list them - we should find INBOX
      @mailbox.imap.list('', '*').each do |info|
        @folders[info.name] = IMAPFolder.new(@mailbox, info.name, @username, info.attr, info.delim)
      end
    end
    @folders
  end
end

class IMAPFolder
  attr_reader :mailbox
  attr_reader :name
  attr_reader :utf7_name
  attr_reader :username
  attr_reader :delim
  attr_reader :attribs
  
  attr_writer :cached
  attr_writer :mcached
  
  cattr_accessor :logger
	
  @@fetch_attr = ['ENVELOPE','BODYSTRUCTURE', 'FLAGS', 'UID', 'RFC822.SIZE']
	
  def initialize(mailbox, utf7_name, username, attribs, delim)
    @mailbox = mailbox
    @utf7_name = utf7_name
    @name = Net::IMAP.decode_utf7 utf7_name
    @username = username
    @messages = Array.new
    @delim = delim
    @attribs = attribs
    @cached = false
    @mcached = false
  end
  
  def activate
    if(@mailbox.selected_mailbox != @name)
      @mailbox.selected_mailbox = @name
      @mailbox.imap.select(@utf7_name)
      load_total_unseen if !@cached
    end
  end
  
  # Just delete message without interaction with Trash folder
  def delete(message)
    activate
    uid = (message.kind_of?(Integer) ? message : message.uid)
    @mailbox.imap.uid_store(uid, "+FLAGS", :Deleted)
    @mailbox.imap.expunge
    # Sync with trash cannot be made - new uid generated - so just delete message from current folder
    ImapMessage.delete_all(["username = ? and folder_name = ? and uid = ?", @username, @name, uid])
    @cached = false
  end
  
  # Deleted messages - move to trash folder
  def delete_multiple(uids)
    # ensure we have trash folder
    begin
      @mailbox.imap.create(CDF::CONFIG[:mail_trash])
      @mailbox.reload
    rescue  
    end
    move_multiple(uids, CDF::CONFIG[:mail_trash])
  end
  
  def copy(message, dst_folder)
    uid = (message.kind_of?(Integer) ? message : message.uid)
    activate
    @mailbox.imap.uid_copy(uid, dst_folder)
    @mailbox.folders[dst_folder].cached = false if @mailbox.folders[dst_folder]
    @mailbox.folders[dst_folder].mcached = false if @mailbox.folders[dst_folder]
  end
  
  def copy_multiple(message_uids, dst_folder)
    activate
    @mailbox.imap.uid_copy(message_uids, dst_folder)
    @mailbox.folders[dst_folder].cached = false if @mailbox.folders[dst_folder]
    @mailbox.folders[dst_folder].mcached = false if @mailbox.folders[dst_folder]
  end
	
  def move(message, dst_folder)
    uid = (message.kind_of?(Integer) ? message : message.uid)
    activate
    @mailbox.imap.uid_copy(uid, dst_folder)
    @mailbox.imap.uid_store(uid, "+FLAGS", :Deleted)
    @mailbox.folders[dst_folder].cached = false if @mailbox.folders[dst_folder]
    @mailbox.folders[dst_folder].mcached = false if @mailbox.folders[dst_folder]
    @mailbox.imap.expunge
    ImapMessage.delete_all(["username = ? and folder_name = ? and uid = ? ", @username, @name, uid])
    @cached = false
    @mcached = false
  end
  
  def move_multiple(message_uids, dst_folder)
    activate
    @mailbox.imap.uid_copy(message_uids, @mailbox.folders[dst_folder].utf7_name)
    @mailbox.imap.uid_store(message_uids, "+FLAGS", :Deleted)
    @mailbox.folders[dst_folder].cached = false if @mailbox.folders[dst_folder]
    @mailbox.folders[dst_folder].mcached = false if @mailbox.folders[dst_folder]
    @mailbox.imap.expunge
    ImapMessage.delete_all(["username = ? and folder_name = ? and uid in ( ? )", @username, @name, message_uids])
    @cached = false
    @mcached = false
  end
	
  def mark_read(message_uid)
  	activate
    cached = ImapMessage.find(:first, :conditions => ["username = ? and folder_name = ? and uid = ?", @username, @name, message_uid])
    if cached.unread
      cached.unread = false
      cached.save
      @mailbox.imap.select(@name)
      @mailbox.imap.uid_store(message_uid, "+FLAGS", :Seen)
      @unseen_messages = @unseen_messages - 1
    end
  end
  
  def mark_unread(message_uid)
  	activate
    cached = ImapMessage.find(:first, :conditions => ["username = ? and folder_name = ? and uid = ?", @username, @name, message_uid])
    if !cached.unread
      cached.unread = true
      cached.save
      @mailbox.imap.select(@name)
      @mailbox.imap.uid_store(message_uid, "-FLAGS", :Seen)
      @unseen_messages = @unseen_messages + 1
    end
  end
  
  def expunge
    activate
    @mailbox.imap.expunge
  end

  def synchronize_cache(offset=0, limit = 10)
    to = (limit - 1)+offset
    startSync = Time.now
    activate
    startUidFetch = Time.now

    #Count all messages
    count = @mailbox.imap.fetch(1..-1, "UID")
    to = count.size if count.size < to
    offset = to if offset > to
    
    range = (offset..to)
    logger.info range.inspect

    server_messages = @mailbox.imap.fetch(range, "(UID FLAGS)")
    #server_messages = @mailbox.imap.uid_fetch(sequence_uids, ["UID", "FLAGS"])
    
    startDbFetch = Time.now
    cached_messages = ImapMessage.find(:all, :conditions => ["username = ? and folder_name = ?", @username, @name])
    
    cached_unread_uids = Array.new
    cached_read_uids = Array.new
    uids_to_be_deleted = Array.new
    
    cached_messages.each { |msg| 
      cached_unread_uids << msg.uid if msg.unread
      cached_read_uids << msg.uid unless msg.unread
      uids_to_be_deleted << msg.uid
    }
    
    uids_to_be_fetched = Array.new
    server_msg_uids = Array.new
    
    uids_unread = Array.new
    uids_read = Array.new
    
    server_messages.each { |server_msg| 
      uid, flags = server_msg.attr['UID'], server_msg.attr['FLAGS']
      server_msg_uids << uid
      unless uids_to_be_deleted.include?(uid)
        uids_to_be_fetched << uid
      else
        if flags.member?(:Seen) && cached_unread_uids.include?(uid)
          uids_read << uid
        elsif !flags.member?(:Seen) && cached_read_uids.include?(uid)
          uids_unread << uid
        end	
      end
      uids_to_be_deleted.delete(uid)
    } unless server_messages.nil?
    
    ImapMessage.delete_all(["username = ? and folder_name = ? and uid in ( ? )", @username, @name, uids_to_be_deleted]) unless uids_to_be_deleted.empty?
    ImapMessage.update_all('unread = 0', ["username = ? and folder_name = ? and uid in ( ? )", @username, @name, uids_read]) unless uids_read.empty?
    ImapMessage.update_all('unread = 1', ["username = ? and folder_name = ? and uid in ( ? )", @username, @name, uids_unread])  unless uids_unread.empty?
    
    
    # fetch and store not cached messages
    unless uids_to_be_fetched.empty? 
      logger.debug("About to fetch #{uids_to_be_fetched.join(",")}")
      uids_to_be_fetched.each_slice(20) do |slice|
        fetch_uids(slice)
      end
    end	
    #FIX: @mcached = true
    logger.debug("Synchonization done for folder #{@name} in #{Time.now - startSync} ms.")
  end
  
  def fetch_uids(uids)
      imapres = @mailbox.imap.uid_fetch(uids, @@fetch_attr)
      imapres.each { |cache| 
        envelope = cache.attr['ENVELOPE'];
        message = ImapMessage.create( :folder_name => @name, 
                                      :username => @username,
                                      :msg_id => envelope.message_id,
                                      :uid => cache.attr['UID'],
                                      :from_addr => envelope.from,
                                      :to_addr => envelope.to,
                                      :subject => envelope.subject,
                                      :content_type => cache.attr['BODYSTRUCTURE'].multipart? ? 'multipart' : 'text',
                                      :date => envelope.date,
                                      :unread => !(cache.attr['FLAGS'].member? :Seen),
                                      :size => cache.attr['RFC822.SIZE'])
      }
  end

  def messages_rev(page, pages_num, rows_num, sort = 'data desc') 
    offset = pages_num - page * rows_num 
    limit = rows_num 
    if offset < 1 
      limit = limit + offset 
      offset = 0 
    end 
    messages(offset, limit, sort) 
  end 
  
  def messages(offset = 0, limit = 10, sort = 'date desc')
    # Synchronize first retrieval time
    synchronize_cache(offset+1, limit) #unless @mcached
    
    if limit == -1
      @messages = ImapMessage.find(:all, :conditions => ["username = ? and folder_name = ?", @username, @name], :order => sort)
    else
      @messages = ImapMessage.find(:all, :conditions => ["username = ? and folder_name = ?", @username, @name], :order => sort )
    end	
  end
  
  def messages_search(query = ["ALL"], sort = 'date desc')
    activate
    uids = @mailbox.imap.uid_search(query)
    if uids.size > 1
      ImapMessage.find(:all, :conditions => ["username = ? and folder_name = ? and uid in ( ? )", @username, @name, uids], :order => sort )
    elsif uids.size == 1
      ImapMessage.find(:all, :conditions => ["username = ? and folder_name = ? and uid = ? ", @username, @name, uids.first], :order => sort )
    else
      return Array.new
    end
    
  end
  
  def message(uid)
    activate
    message = ImapMessage.find(:first, :conditions => ["username = ? and folder_name = ? and uid = ?", @username, @name, uid])
    message.set_folder(self)
    message
  end
  
  def unseen
    activate
    load_total_unseen if !@cached
    @unseen_messages 
  end
  
  def total
    activate
    load_total_unseen if !@cached
    @total_messages
  end
  
  def load_total_unseen
    stat = @mailbox.imap.status(@utf7_name, ["MESSAGES", "UNSEEN"])
    @total_messages, @unseen_messages = stat["MESSAGES"], stat['UNSEEN']
    @cached = true
  end
  
  def update_status
    @status ||= @mailbox.imap.status(@utf7_name, ["MESSAGES"])
  end
  
  def subscribe
    @mailbox.imap.subscribe(@utf7_name)
  end

  def trash?
    self.name == CDF::CONFIG[:mail_trash]
  end
end
