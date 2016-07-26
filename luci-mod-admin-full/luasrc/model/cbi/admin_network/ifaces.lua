-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Copyright 2008-2011 Jo-Philipp Wich <jow@openwrt.org>
-- Copyright 2015 OVH <OverTheBox@ovh.net>
-- Licensed to the public under the Apache License 2.0.

local fs = require "nixio.fs"
local ut = require "luci.util"
local pt = require "luci.tools.proto"
local nw = require "luci.model.network"
local fw = require "luci.model.firewall"

arg[1] = arg[1] or ""

local has_dnsmasq  = fs.access("/etc/config/dhcp")
local has_firewall = fs.access("/etc/config/firewall")

m = Map("network", translate("Interfaces") .. " - " .. arg[1]:upper(), translate("On this page you can configure the network interfaces. You can bridge several interfaces by ticking the \"bridge interfaces\" field and enter the names of several network interfaces separated by spaces. You can also use <abbr title=\"Virtual Local Area Network\">VLAN</abbr> notation <samp>INTERFACE.VLANNR</samp> (<abbr title=\"for example\">e.g.</abbr>: <samp>eth0.1</samp>)."))
m.redirect = luci.dispatcher.build_url("admin", "network", "network")
m:chain("wireless")

if has_firewall then
	m:chain("firewall")
end

nw.init(m.uci)
fw.init(m.uci)


local net = nw:get_network(arg[1])

local function backup_ifnames(is_bridge)
	if not net:is_floating() and not m:get(net:name(), "_orig_ifname") then
		local ifcs = net:get_interfaces() or { net:get_interface() }
		if ifcs then
			local _, ifn
			local ifns = { }
			for _, ifn in ipairs(ifcs) do
				ifns[#ifns+1] = ifn:name()
			end
			if #ifns > 0 then
				m:set(net:name(), "_orig_ifname", table.concat(ifns, " "))
				m:set(net:name(), "_orig_bridge", tostring(net:is_bridge()))
			end
		end
	end
end


-- redirect to overview page if network does not exist anymore (e.g. after a revert)
if not net then
	luci.http.redirect(luci.dispatcher.build_url("admin/network/network"))
	return
end

-- protocol switch was requested, rebuild interface config and reload page
if m:formvalue("cbid.network.%s._switch" % net:name()) then
	-- get new protocol
	local ptype = m:formvalue("cbid.network.%s.proto" % net:name()) or "-"
	local proto = nw:get_protocol(ptype, net:name())
	if proto then
		-- backup default
		backup_ifnames()

		-- if current proto is not floating and target proto is not floating,
		-- then attempt to retain the ifnames
		--error(net:proto() .. " > " .. proto:proto())
		if not net:is_floating() and not proto:is_floating() then
			-- if old proto is a bridge and new proto not, then clip the
			-- interface list to the first ifname only
			if net:is_bridge() and proto:is_virtual() then
				local _, ifn
				local first = true
				for _, ifn in ipairs(net:get_interfaces() or { net:get_interface() }) do
					if first then
						first = false
					else
						net:del_interface(ifn)
					end
				end
				m:del(net:name(), "type")
			end

		-- if the current proto is floating, the target proto not floating,
		-- then attempt to restore ifnames from backup
		elseif net:is_floating() and not proto:is_floating() then
			-- if we have backup data, then re-add all orphaned interfaces
			-- from it and restore the bridge choice
			local br = (m:get(net:name(), "_orig_bridge") == "true")
			local ifn
			local ifns = { }
			for ifn in ut.imatch(m:get(net:name(), "_orig_ifname")) do
				ifn = nw:get_interface(ifn)
				if ifn and not ifn:get_network() then
					proto:add_interface(ifn)
					if not br then
						break
					end
				end
			end
			if br then
				m:set(net:name(), "type", "bridge")
			end

		-- in all other cases clear the ifnames
		else
			local _, ifc
			for _, ifc in ipairs(net:get_interfaces() or { net:get_interface() }) do
				net:del_interface(ifc)
			end
			m:del(net:name(), "type")
		end

		-- clear options
		local k, v
		for k, v in pairs(m:get(net:name())) do
			if k:sub(1,1) ~= "." and
			   k ~= "type" and
			   k ~= "ifname" and
			   k ~= "_orig_ifname" and
			   k ~= "_orig_bridge"
			then
				m:del(net:name(), k)
			end
		end

		-- set proto
		m:set(net:name(), "proto", proto:proto())
		m.uci:save("network")
		m.uci:save("wireless")

		-- reload page
		luci.http.redirect(luci.dispatcher.build_url("admin/network/network", arg[1]))
		return
	end
end

-- dhcp setup was requested, create section and reload page
if m:formvalue("cbid.dhcp._enable._enable") then
	m.uci:section("dhcp", "dhcp", arg[1], {
		interface = arg[1],
		start     = "100",
		limit     = "150",
		leasetime = "12h"
	})

	m.uci:save("dhcp")
	luci.http.redirect(luci.dispatcher.build_url("admin/network/network", arg[1]))
	return
end

local ifc = net:get_interface()

s = m:section(NamedSection, arg[1], "interface", translate("Common Configuration"))
s.addremove = false

s:tab("general",  translate("General Setup"))
s:tab("advanced", translate("Advanced Settings"))
s:tab("physical", translate("Physical Settings"))
s:tab("trafficcontrol", translate("Traffic Control"))

if has_firewall then
	s:tab("firewall", translate("Firewall Settings"))
end


st = s:taboption("general", DummyValue, "__status", translate("Status"))

local function set_status()
	-- if current network is empty, print a warning
	if not net:is_floating() and net:is_empty() then
		st.template = "cbi/dvalue"
		st.network  = nil
		st.value    = translate("There is no device assigned yet, please attach a network device in the \"Physical Settings\" tab")
	else
		st.template = "admin_network/iface_status"
		st.network  = arg[1]
		st.value    = nil
	end
end

m.on_init = set_status
m.on_after_save = set_status

l = s:taboption("general", Value, "label", translate("Label"))
l.rmempty = true
l:depends("multipath", "on")
l:depends("multipath", "master")
l:depends("multipath", "backup")
l:depends("multipath", "handover")

p = s:taboption("general", ListValue, "proto", translate("Protocol"))
p.default = net:proto()

if not net:is_installed() then
	p_install = s:taboption("general", Button, "_install")
	p_install.title      = translate("Protocol support is not installed")
	p_install.inputtitle = translate("Install package %q" % net:opkg_package())
	p_install.inputstyle = "apply"
	p_install:depends("proto", net:proto())

	function p_install.write()
		return luci.http.redirect(
			luci.dispatcher.build_url("admin/system/packages") ..
			"?submit=1&install=%s" % net:opkg_package()
		)
	end
end


p_switch = s:taboption("general", Button, "_switch")
p_switch.title      = translate("Really switch protocol?")
p_switch.inputtitle = translate("Switch protocol")
p_switch.inputstyle = "apply"

local _, pr
for _, pr in ipairs(nw:get_protocols()) do
	p:value(pr:proto(), pr:get_i18n())
	if pr:proto() ~= net:proto() then
		p_switch:depends("proto", pr:proto())
	end
end


auto = s:taboption("advanced", Flag, "auto", translate("Bring up on boot"))
auto.default = (net:proto() == "none") and auto.disabled or auto.enabled

-- Add MPTCP
if fs.access("/proc/sys/net/mptcp") then
    mptcp = s:taboption("advanced", ListValue, "multipath", translate("Multipath TCP"))
    mptcp:value("on", translate("enabled"))
    mptcp:value("off", translate("disabled"))
    mptcp:value("master", translate("master"))
    mptcp:value("backup", translate("backup"))
    mptcp:value("handover", translate("handover"))
    mptcp.default = "off"
end

delegate = s:taboption("advanced", Flag, "delegate", translate("Use builtin IPv6-management"))
delegate.default = delegate.enabled


if not net:is_virtual() then
    iftype = s:taboption("physical", ListValue, "type", translate("Type of the interface"))
    iftype:value("", translate("Default"))
    iftype:value("macvlan", translate("Create a macvlan sub interface"))
    iftype:value("bridge", translate("Create a bridge over multiple interfaces"))
    iftype:depends("proto", "static")
    iftype:depends("proto", "dhcp")
    iftype:depends("proto", "none")

	stp = s:taboption("physical", Flag, "stp", translate("Enable <abbr title=\"Spanning Tree Protocol\">STP</abbr>"),
		translate("Enables the Spanning Tree Protocol on this bridge"))
	stp:depends("type", "bridge")
	stp.rmempty = true

--    macsource = s:taboption("physical", DynamicList, "vlanmacs", translate("Add MACs address to enable source mode"))
--    macsource:depends("type", "macvlan")
--    macsource.rmempty = true
end

macvlanmaster = s:taboption("physical", Value, "interface", translate("Master interface"))
macvlanmaster.default = "eth0"
macvlanmaster:depends("type", "macvlan")

if not net:is_floating() then
	ifname_single = s:taboption("physical", Value, "ifname_single", translate("Interface"))
	ifname_single.template = "cbi/network_ifacelist"
	ifname_single.widget = "radio"
	ifname_single.nobridges = true
	ifname_single.rmempty = false
	ifname_single.network = arg[1]
	ifname_single:depends("type", "")

	function ifname_single.cfgvalue(self, s)
		-- let the template figure out the related ifaces through the network model
		return nil
	end

	function ifname_single.write(self, s, val)
		local i
		local new_ifs = { }
		local old_ifs = { }

		for _, i in ipairs(net:get_interfaces() or { net:get_interface() }) do
			old_ifs[#old_ifs+1] = i:name()
		end

		for i in ut.imatch(val) do
			new_ifs[#new_ifs+1] = i

			-- if this is not a bridge, only assign first interface
			if self.option == "ifname_single" then
				break
			end
		end

		table.sort(old_ifs)
		table.sort(new_ifs)

		for i = 1, math.max(#old_ifs, #new_ifs) do
			if old_ifs[i] ~= new_ifs[i] then
				backup_ifnames()
				for i = 1, #old_ifs do
					net:del_interface(old_ifs[i])
				end
				for i = 1, #new_ifs do
					net:add_interface(new_ifs[i])
				end
				break
			end
		end
	end
end

if not net:is_virtual() then
	ifname_multi = s:taboption("physical", Value, "ifname_multi", translate("Interface"))
	ifname_multi.template = "cbi/network_ifacelist"
	ifname_multi.nobridges = true
	ifname_multi.rmempty = false
	ifname_multi.network = arg[1]
	ifname_multi.widget = "checkbox"
	ifname_multi:depends("type", "bridge")
	ifname_multi.cfgvalue = ifname_single.cfgvalue
	ifname_multi.write = ifname_single.write
end

aushape = s:taboption("trafficcontrol", ListValue, "trafficcontrol", translate("Adaptive Shaping"))
aushape:value("off", translate("Disabled"))
aushape:value("static", translate("Static"))
--aushape:value("auto", translate("Adaptive (experimental)"))
aushape.default = "off"
aushape:depends("multipath", "on")
aushape:depends("multipath", "master")
aushape:depends("multipath", "backup")
aushape:depends("multipath", "handover")

download = s:taboption("trafficcontrol", Value, "download", translate("Download bandwidth in kbit/s"))
download.rmempty = true
download:depends("trafficcontrol", "static")

upload = s:taboption("trafficcontrol", Value, "upload", translate("Upload bandwidth in kbit/s"))
upload.rmempty = true
upload:depends("trafficcontrol", "static")
upload:depends("trafficcontrol", "auto")

pingdeleta = s:taboption("trafficcontrol", Value, "pingdelta", translate("Max ping increase in ms before consdering link as congested"))
pingdeleta.default = "100"
pingdeleta.rmempty = true
pingdeleta:depends("trafficcontrol", "auto")

mindownload = s:taboption("trafficcontrol", Value, "mindownload", translate("Minimal download speed in kbit/s"))
mindownload.default = "512"
mindownload.rmempty = true
mindownload:depends("trafficcontrol", "auto")

minupload = s:taboption("trafficcontrol", Value, "minupload", translate("Minimal upload speed in kbit/s"))
minupload.default = "128"
minupload.rmempty = true
minupload:depends("trafficcontrol", "auto")

-- bandwidthdelta = s:taboption("trafficcontrol", Value, "bandwidthdelta", translate("Minimum rate delta in kbit/s between mesures before reloading QoS"))
-- bandwidthdelta.default = "100"
-- bandwidthdelta.rmempty = true
-- bandwidthdelta:depends("trafficcontrol", "auto")

qostimeout = s:taboption("trafficcontrol", Value, "qostimeout", translate("Time in min to keep detected rate"))
qostimeout.default = "30"
qostimeout.rmempty = true
qostimeout:depends("trafficcontrol", "auto")

ratefactor = s:taboption("trafficcontrol", Value, "ratefactor", translate("Factor to apply on mesured rate"))
ratefactor.default = "1"
ratefactor.rmempty = true
ratefactor:depends("trafficcontrol", "auto")

if has_firewall then
	fwzone = s:taboption("firewall", Value, "_fwzone",
		translate("Create / Assign firewall-zone"),
		translate("Choose the firewall zone you want to assign to this interface. Select <em>unspecified</em> to remove the interface from the associated zone or fill out the <em>create</em> field to define a new zone and attach the interface to it."))

	fwzone.template = "cbi/firewall_zonelist"
	fwzone.network = arg[1]
	fwzone.rmempty = false

	function fwzone.cfgvalue(self, section)
		self.iface = section
		local z = fw:get_zone_by_network(section)
		return z and z:name()
	end

	function fwzone.write(self, section, value)
		local zone = fw:get_zone(value)

		if not zone and value == '-' then
			value = m:formvalue(self:cbid(section) .. ".newzone")
			if value and #value > 0 then
				zone = fw:add_zone(value)
			else
				fw:del_network(section)
			end
		end

		if zone then
			fw:del_network(section)
			zone:add_network(section)
		end
	end
end


function p.write() end
function p.remove() end
function p.validate(self, value, section)
	if value == net:proto() then
		if not net:is_floating() and net:is_empty() then
			local ifn = ((br and (br:formvalue(section) == "bridge"))
				and ifname_multi:formvalue(section)
			     or ifname_single:formvalue(section))

			for ifn in ut.imatch(ifn) do
				return value
			end
			return nil, translate("The selected protocol needs a device assigned")
		end
	end
	return value
end


local form, ferr = loadfile(
	ut.libpath() .. "/model/cbi/admin_network/proto_%s.lua" % net:proto()
)

if not form then
	s:taboption("general", DummyValue, "_error",
		translate("Missing protocol extension for proto %q" % net:proto())
	).value = ferr
else
	setfenv(form, getfenv(1))(m, s, net)
end


local _, field
for _, field in ipairs(s.children) do
	if field ~= st and field ~= p and field ~= p_install and field ~= p_switch then
		if next(field.deps) then
			local _, dep
			for _, dep in ipairs(field.deps) do
				dep.deps.proto = net:proto()
			end
		else
			field:depends("proto", net:proto())
		end
	end
end


--
-- Display DNS settings if dnsmasq is available
--

if has_dnsmasq and net:proto() == "static" then
	m2 = Map("dhcp", "", "")

	local has_section = false

	m2.uci:foreach("dhcp", "dhcp", function(s)
		if s.interface == arg[1] then
			has_section = true
			return false
		end
	end)

	if not has_section and has_dnsmasq then

		s = m2:section(TypedSection, "dhcp", translate("DHCP Server"))
		s.anonymous   = true
		s.cfgsections = function() return { "_enable" } end

		x = s:option(Button, "_enable")
		x.title      = translate("No DHCP Server configured for this interface")
		x.inputtitle = translate("Setup DHCP Server")
		x.inputstyle = "apply"

	elseif has_section then

		s = m2:section(TypedSection, "dhcp", translate("DHCP Server"))
		s.addremove = false
		s.anonymous = true
		s:tab("general",  translate("General Setup"))
		s:tab("advanced", translate("Advanced Settings"))
		s:tab("ipv6", translate("IPv6 Settings"))

		function s.filter(self, section)
			return m2.uci:get("dhcp", section, "interface") == arg[1]
		end

		local ignore = s:taboption("general", Flag, "ignore",
			translate("Ignore interface"),
			translate("Disable <abbr title=\"Dynamic Host Configuration Protocol\">DHCP</abbr> for " ..
				"this interface."))

		local start = s:taboption("general", Value, "start", translate("Start"),
			translate("Lowest leased address as offset from the network address."))
		start.optional = true
		start.datatype = "or(uinteger,ip4addr)"
		start.default = "100"

		local limit = s:taboption("general", Value, "limit", translate("Limit"),
			translate("Maximum number of leased addresses."))
		limit.optional = true
		limit.datatype = "uinteger"
		limit.default = "150"

		local ltime = s:taboption("general", Value, "leasetime", translate("Leasetime"),
			translate("Expiry time of leased addresses, minimum is 2 minutes (<code>2m</code>)."))
		ltime.rmempty = true
		ltime.default = "12h"

		local dd = s:taboption("advanced", Flag, "dynamicdhcp",
			translate("Dynamic <abbr title=\"Dynamic Host Configuration Protocol\">DHCP</abbr>"),
			translate("Dynamically allocate DHCP addresses for clients. If disabled, only " ..
				"clients having static leases will be served."))
		dd.default = dd.enabled

		s:taboption("advanced", Flag, "force", translate("Force"),
			translate("Force DHCP on this network even if another server is detected."))

		-- XXX: is this actually useful?
		--s:taboption("advanced", Value, "name", translate("Name"),
		--	translate("Define a name for this network."))

		mask = s:taboption("advanced", Value, "netmask",
			translate("<abbr title=\"Internet Protocol Version 4\">IPv4</abbr>-Netmask"),
			translate("Override the netmask sent to clients. Normally it is calculated " ..
				"from the subnet that is served."))

		mask.optional = true
		mask.datatype = "ip4addr"

		s:taboption("advanced", DynamicList, "dhcp_option", translate("DHCP-Options"),
			translate("Define additional DHCP options, for example \"<code>6,192.168.2.1," ..
				"192.168.2.2</code>\" which advertises different DNS servers to clients."))

		for i, n in ipairs(s.children) do
			if n ~= ignore then
				n:depends("ignore", "")
			end
		end

		o = s:taboption("ipv6", ListValue, "ra", translate("Router Advertisement-Service"))
		o:value("", translate("disabled"))
		o:value("server", translate("server mode"))
		o:value("relay", translate("relay mode"))
		o:value("hybrid", translate("hybrid mode"))

		o = s:taboption("ipv6", ListValue, "dhcpv6", translate("DHCPv6-Service"))
		o:value("", translate("disabled"))
		o:value("server", translate("server mode"))
		o:value("relay", translate("relay mode"))
		o:value("hybrid", translate("hybrid mode"))

		o = s:taboption("ipv6", ListValue, "ndp", translate("NDP-Proxy"))
		o:value("", translate("disabled"))
		o:value("relay", translate("relay mode"))
		o:value("hybrid", translate("hybrid mode"))

		o = s:taboption("ipv6", ListValue, "ra_management", translate("DHCPv6-Mode"))
		o:value("", translate("stateless"))
		o:value("1", translate("stateless + stateful"))
		o:value("2", translate("stateful-only"))
		o:depends("dhcpv6", "server")
		o:depends("dhcpv6", "hybrid")
		o.default = "1"

		o = s:taboption("ipv6", Flag, "ra_default", translate("Always announce default router"),
		        translate("Announce as default router even if no public prefix is available."))
		o:depends("ra", "server")
		o:depends("ra", "hybrid")

		s:taboption("ipv6", DynamicList, "dns", translate("Announced DNS servers"))
		s:taboption("ipv6", DynamicList, "domain", translate("Announced DNS domains"))

	else
		m2 = nil
	end
end


return m, m2
