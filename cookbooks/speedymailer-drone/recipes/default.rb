include_recipe "apt"
include_recipe "git"
include_recipe "ruby::1.9.1"
include_recipe "rubygems"

package 'libgvc5'
package 'libgraphviz-dev'
package 'libmagickcore-dev'
package 'libmagickcore4-extra'
package 'libmagickwand-dev'
package 'libxslt-dev'
package 'libxml2-dev'
package 'mailutils'
package 'curl'
package 'mongodb'

#kill to free up memory
kill_action = execute "ps aux | grep 'rsyslog\|mono\|mongod' | grep -v grep | awk '{print $2}' | xargs kill -9" do
  action :nothing
end
kill_action.run_action(:run)

#write ip and domain
update_apt_get = execute "/usr/bin/apt-get update" do
  action :nothing
end
update_apt_get.run_action(:run)

dns_utils = package "dnsutils" do
  action :nothing
end

dns_utils.run_action(:install)

node.default["drone"]["ip"] = `/usr/bin/wget -q -O- http://ipecho.net/plain`

drone_domain = `/usr/bin/dig +noall +answer -x #{node.default["drone"]["ip"]} | awk '{$5=substr($5,1,length($5)-1); print $5}' | tr  -d '\n'`
if drone_domain.empty? then
  abort "No reverse dns found"
end

node.default["drone"]["domain"] = drone_domain

#stop apache - we don't need it
service "apache2" do
  action :stop
end

#add backports repo
script "add-backport-deb" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
      echo 'deb http://archive.ubuntu.com/ubuntu precise-backports main restricted universe multiverse' >> /etc/apt/sources.list
      apt-get update
  EOH

  not_if "cat /etc/apt/sources.list | grep precise-backports"
end

#install mono
apt_repository "mono-rep" do
  uri "http://ppa.launchpad.net/borgdylan/ppa/ubuntu"
  distribution node['lsb']['codename']
  components ["main"]
  keyserver "keyserver.ubuntu.com"
  key "4B47C289FADDF7CF01380548FAAB7362B99C283A"
  deb_src true

  not_if "cat /etc/apt/sources.list.d/* | grep borgdylan"
end

apt_repository "rsyslog" do
  uri "http://ppa.launchpad.net/ukplc-team/testing/ubuntu"
  distribution node['lsb']['codename']
  components ["main"]
  keyserver "keyserver.ubuntu.com"
  key "F262AA585E04325397D7C8BA1C7DAF1E1A39EA92"
  deb_src true

  not_if "cat /etc/apt/sources.list.d/* | grep ukplc-team"
end

package 'mono-runtime'
package 'mono-devel'

#set host to be a mail server

file "/etc/hostname" do
  content "mail"
end

#set the domain in the hosts file
script "add-domain-to-hosts-file" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
        original_hostname=$(hostname)
        cat /etc/hosts | grep -Ev $original_hostname | sudo tee /etc/hosts
                
        echo "#{node[:drone][:ip]} mail.#{node[:drone][:domain]} mail" >> /etc/hosts
        echo "#{node[:drone][:ip]} localhost.localdomain mail" >> /etc/hosts

        service hostname restart
  EOH
end

execute "create-deploy-dirs" do
  command "mkdir -p /deploy/domain-keys && mkdir -p /deploy/utils"
end

#configure postfix

service "sendmail" do
  action :stop
end

package 'postfix'
package 'postfix-pcre'
package 'dk-filter'

script "install-open-dkim" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
      apt-get install opendkim/precise-backports opendkim-tools/precise-backports -y
  EOH
end

template "/etc/postfix/main.cf" do
  source "main.cf.erb"
  mode 0664
  owner "root"
  group "root"
  variables({
                :domain => node[:drone][:domain]
            })
end

template "/etc/postfix/header_checks" do
  source "header_checks.erb"
  mode 0664
  owner "root"
  group "root"
end

template "/etc/opendkim.conf" do
  source "opendkim.conf.erb"
  mode 0664
  owner "root"
  group "root"
  variables({
                :domain => node[:drone][:domain]
            })
end

template "/etc/default/opendkim" do
  source "opendkim.erb"
  mode 0664
  owner "root"
  group "root"
end

template "/etc/mail/dkim-InternalHosts.txt" do
  source "dkim-InternalHosts.txt.erb"
  mode 0664
  owner "root"
  group "root"
end

template "/etc/default/dk-filter" do
  source "dk-filter.erb"
  mode 0664
  owner "root"
  group "root"
  variables({
                :domain => node[:drone][:domain]
            })
end

script "create-dkim-key" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
      opendkim-genkey -t -s mail -d #{node[:drone][:domain]}
      cp mail.private /etc/mail/dkim.key
      cp mail.txt /deploy/domain-keys/dkim-dns.txt
  EOH

  not_if "test -f /deploy/domain-keys/dkim-dns.txt"
end

script "create-domain-key" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
      openssl genrsa -out private.key 1024
      openssl rsa -in private.key -out public.key -pubout -outform PEM
      cp private.key /etc/mail/domainkey.key
      cp public.key /deploy/domain-keys/domain-keys-dns.txt
      service dk-filter stop
      service dk-filter start
  EOH

  not_if "test -f /deploy/domain-keys/domain-keys-dns.txt"
end

service "postfix" do
  action :start
end

service "opendkim" do
  action :restart
end

#clean deferred queue cron job
script "setup drone alias" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
        crontab -l > mycron
        sed -i '/no crontab for root/d' mycron
        echo "0 */1 * * * /usr/sbin/postsuper -d ALL deferred" >> mycron
        crontab mycron
        rm mycron
  EOH
end

#install gems needed to run the rake tasks for speedymailer

gem_package "rubygems-update"

execute "update-gems" do
  command "update_rubygems"
end

gem_package "albacore" do
  not_if "gem list | grep albacore"
end

gem_package "nokogiri" do
  not_if "gem list | grep nokogiri"
end

gem_package "rake" do
  not_if "gem list | grep rake"
end

gem_package "thor" do
  not_if "gem list | grep thor"
end

gem_package "mail" do
  not_if "gem list | grep mail"
end

gem_package "mongo" do
  not_if "gem list | grep mongo"
end

gem_package "bson_ext" do
  not_if "gem list | grep bson_ext"
end

gem_package "point" do
  not_if "gem list | grep point"
end

script "install proctable" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
      gem install sys-proctable --platform linux
  EOH

  not_if "gem list | grep proctable"
end

#setup mongo

service "mongodb" do
  action :stop
end

directory "/deploy/mongo-data" do
  action :create
  recursive true
  not_if "test -d /deploy/mongo-data"
end

execute "start-mongo" do
  command "mongod --fork --dbpath /deploy/mongo-data --port 27027 --nohttpinterface --nojournal --logpath /var/log/mongodb/drone.log"
end

#ewfresh rsyslog
package 'rsyslog'
package 'rsyslog-mongodb'

#setup rsyslog logging to mongo

template "/etc/rsyslog.d/10-mongodb.conf" do
  source "10-mongodb.conf.erb"
  mode 0664
  owner "root"
  group "root"
end

script "rsyslog refresh" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
      sed -i '/imklog/d' /etc/rsyslog.conf
      ps aux | grep rsyslog | grep -v grep | awk '{print $2}' | xargs kill -9
  EOH
end

execute "setup-port-forwarding" do
  command "iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080"
  not_if " iptables -t nat -L -n -v | grep 8080"
end

#deploy scripts

template "/root/.bash_profile" do
  source ".bash_profile.erb"
  mode 0664
  owner "root"
  group "root"
end

script "setup drone alias" do
  interpreter "bash"
  user "root"
  cwd "/tmp"
  code <<-EOH
      echo "alias drone='drone-admin.rb'" >> /root/.bashrc 
  EOH

  not_if "grep drone /root/.bashrc"
end

#deploy the drone

deploy "/deploy/drones" do
  repo "https://github.com/mamluka/SpeedyMailer.git"
  branch "master"
  keep_releases 1

  symlink_before_migrate.clear
  purge_before_symlink.clear
  create_dirs_before_symlink.clear
  symlinks.clear

  restart_command do
    current_release = release_path
    drone_path = "#{current_release}/Out/Drone"

    execute "build-drone-with-mono" do
      cwd current_release
      command "rake mono:build"
    end

    execute "kill-running-drone" do
      cwd drone_path
      command "ps aux | grep mono | grep -v grep | awk '{print $2}' | xargs kill -9"
      only_if "ps aux | grep mono | grep -v grep"
    end

    execute "copy-utils" do
      cwd drone_path
      command "cp #{current_release}/Utils/* /deploy/utils/ && chmod +x /deploy/utils/*.rb"
      end

    execute "register-mail-dns-records" do
      cwd drone_path
      command "ruby /deploy/utils/create_dns_zones.rb"
    end

    execute "run-drone" do
      cwd drone_path
      command "nohup mono SpeedyMailer.Drones.exe -s #{node[:drone][:master]} &"
    end
  end
end
