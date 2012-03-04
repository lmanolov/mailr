require 'cdfutils'

module Mail2Screen
  def mail2html(mail, msg_id)
    footer = ""
    parsed_body = create_body(mail, msg_id, footer)
    
    ret = "<table class='messageheader' border='0' cellpadding='0' cellspacing='0' >\n"
    ret << "<tbody>\n"
    ret << "  <tr><td class='label' nowrap='nowrap'>#{t :from}:</td><td>#{address(mail.from_addrs, @msg_id)}</td></tr>\n"
    ret << "  <tr><td class='label' nowrap='nowrap'>#{t :to}:</td><td>#{address(mail.to_addrs, @msg_id)}</td></tr>\n"
    if @mail.cc_addrs
      ret << "  <tr><td class='label' nowrap='nowrap'>#{t :cc}:</td><td>#{address(mail.cc_addrs, @msg_id)}</td></tr>\n"
    end
    if @mail.bcc_addrs
      ret << "  <tr><td class='label' nowrap='nowrap'>#{t :bcc}:</td><td>#{address(mail.bcc_addrs, @msg_id)}</td></tr>\n"
    end
    ret << "  <tr><td class='label' nowrap='nowrap'>#{t :subject}:</td><td>#{h(mime_encoded?(mail["subject"].encoded) ? mime_decode(mail["subject"].encoded) : mail.subject)}</td>\n" 
    ret << "  <tr><td class='label' nowrap='nowrap'>#{t :date}:</td><td>#{h message_date(mail.date)}</td></tr>\n"
    if footer != ''
    	ret << "  <tr><td class='label' nowrap='nowrap'>#{image_tag('attachment.png')}</td><td>#{footer}</td></tr>\n"
    end
    ret << "  </tbody>\n"
    ret << "</table>\n"

    ret << "<div class='msgpart'>\n"
    ret << parsed_body
    ret << "</div>\n"
  end
    
  def create_body(mail, msg_id, footer)
    charset = (mail.charset.nil? ? 'iso-8859-1' : mail.charset)
    if mail.multipart?
      ret = ""
      if mail.content_type == 'multipart/alternative'
        # take only HTML part
        mail.parts.each { |part|
          if part.content_type == "text/html" or part.multipart?
            ret << create_body(part, msg_id, footer)
          end
        }
        return ret  
      else
        mail.parts.each { |part|
          if part.multipart?
            ret << create_body(part, msg_id, footer)
          else
          	footer << ", " if footer != ''
            footer << add_attachment(part.header['content-type'], msg_id)
            if part.content_type == "text/plain" or part.content_type.nil?
              charset = (part.charset.nil? ? charset : mail.charset)
              ret << add_text(part, part.transfer_encoding, charset)
            elsif  part.content_type == "text/html"
              charset = (part.charset.nil? ? charset : mail.charset)
              ret << add_html(part, part.transfer_encoding, charset)
            elsif part.content_type.include?("image/")
              ctype = part.header['content-type']
              ret << add_image(ctype, msg_id)
            elsif part.content_type.include?("message/rfc822")  
              ret << "<br/>#{_('Follows attached message')}:<hr/>" << mail2html(TMail::Mail.parse(part.body), msg_id)
            end
          end
        }
        return ret
      end  
    else
      ret = ""
      if mail.content_type == "text/plain" or mail.content_type.nil?
        ret << add_text(mail, mail.transfer_encoding, charset)
      elsif  mail.content_type == "text/html"
        ret << add_html(mail, mail.transfer_encoding, charset)
      end
      return ret
    end
  end
  
  def add_text(part, encoding, charset)
    CGI.escapeHTML(decode_part_text("#{part}", encoding, charset)).gsub(/\r\n/,"<br/>").gsub(/\r/, "<br/>").gsub(/\n/,"<br/>") 
  end

  def add_html(part, encoding, charset) 
    strip_html(decode_part_text("#{part}", encoding, charset))
  end
  
  def decode_part_text(part_str, encoding, charset)
    # Parse mail
    header, text = "", ""
   
    # Get header and body
    #Content-type: text/plain; charset="ISO-8859-1"
    #Content-transfer-encoding: quoted-printable 
    isBody = false
    part_str.each_line { |line| 
      if isBody
        text << line
      else
        if line.strip == ""
          isBody = true
        else
          header << line
        end
      end
    }
    # Manage encoding
    if not(encoding.nil?) and encoding.downcase == "quoted-printable"
      ret = from_qp(text)
    elsif not(encoding.nil?) and encoding.downcase == "base64"
      ret = "#{text.unpack("m")}"
    else  
      ret = text
    end
    # manage charset
    if ret.nil? or charset.nil? or charset.downcase == "utf-8"
      return ret
    else
      begin
        return Iconv.conv("UTF-8",charset.downcase, ret)
      rescue Exception => ex
        RAILS_DEFAULT_LOGGER.debug("Exception occured #{ex}\n#{ex.backtrace.join('\n')}")
        return ret
      end
    end 
  end
  
  def add_attachment(content_type, msg_id)
    filename = (content_type.nil? or content_type['name'].nil? ? "" : content_type['name'])
    if filename == ""
      ""
    else
      "<span class='attachment'>&nbsp;<a href='/webmail/download?msg_id=#{msg_id}&ctype=" << CGI.escape(filename) << "'>#{filename}</a></span>"
    end
  end
  
  def add_image(content_type, msg_id)
    filename = (content_type.nil? or content_type['name'].nil? ? "" : content_type['name'])
    "<hr/><span class='attachment'><br/><img src='/webmail/download?msg_id=#{msg_id}&ctype=" << CGI.escape(filename) << "' alt='#{filename}'/></span>"
  end
  
  def friendly_address(addr)
    addr.kind_of?(Net::IMAP::Address) ? ((addr.name.nil? or addr.name.strip == "") ? "#{addr.mailbox}@#{addr.host}" : "#{(mime_encoded?(addr.name.strip) ? mime_decode(addr.name.to_s): addr.name.to_s)}<#{addr.mailbox}@#{addr.host}>") : ((addr.name.nil? or addr.name.strip == "") ? "#{addr.spec}" : "#{(mime_encoded?(addr.name.strip) ? mime_decode(addr.name.to_s): addr.name.to_s)}<#{addr.spec}>")
  end
  
  def friendly_address_or_name(addr)
    if addr.kind_of?(Net::IMAP::Address) 
      ((addr.name.nil? or addr.name.to_s == "") ? "#{addr.mailbox}@#{addr.host}" : (mime_encoded?(addr.name.to_s) ? mime_decode(addr.name.to_s): addr.name.to_s)) 
    else
      ((addr.nil? or addr.to_s == "") ? "#{addr.to_s}" : (mime_encoded?(addr.to_s) ? mime_decode(addr.to_s): addr.to_s))
    end
  end
  
  def add_to_contact(addr, msg_id)
    "&nbsp;<a href='/contact/add_from_mail?cstr=#{CGI.escape(friendly_address(addr))}&retmsg=#{msg_id}'>Agregar a contactos</a>"
  end
  
  def short_address(addresses)
    ret = ""
    addresses.each { |addr| #split(/,\s*/)
      ret << "," unless ret == ""
      ret << CGI.escapeHTML(friendly_address_or_name(addr))
    } unless addresses.nil?
    ret
  end
  
  def address(addresses, msg_id)
    ret = ""
    addresses.each { |addr| #split(/,\s*/)
      ret << "," unless ret == ""
      ret << CGI.escapeHTML(friendly_address_or_name(addr.encoded)) << add_to_contact(addr, msg_id)
    } unless addresses.nil?
    return ret
  end
end
