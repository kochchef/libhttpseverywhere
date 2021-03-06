/* -*- Mode: vala; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/********************************************************************
# Copyright 2015-2016 Daniel 'grindhold' Brendle
#
# This file is part of libhttpseverywhere.
#
# libhttpseverywhere is free software: you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public License
# as published by the Free Software Foundation, either
# version 3 of the License, or (at your option) any later
# version.
#
# libhttpseverywhere is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
# PURPOSE. See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with libhttpseverywhere.
# If not, see http://www.gnu.org/licenses/.
*********************************************************************/

namespace HTTPSEverywhere {
    /**
     * Errors that may occur when handling {@link HTTPSEverywhere.Ruleset}s
     */
    public errordomain RulesetError {
        /**
         * Gets thrown when a ruleset fails to parse
         */
        PARSE_ERROR
    }

    /**
     * This represents the contents of a HTTPSEverywhere ruleset-file
     * Rulesets contain a set of target-hosts that the rules apply to
     * furthermore it contains a set of regular expressions that determine
     * how to convert a HTTP-URL into the corresponding HTTPS-URL
     */
    public class Ruleset : GLib.Object {
        private string name;
        private string platform;
        private bool default_off;

        private Gee.ArrayList<Rule> rules;
        private Gee.ArrayList<Regex> exclusions;
        private Gee.ArrayList<Target> _targets;
        private string securecookie;

        /**
         * The target-hosts this ruleset applies to
         */
        public Gee.ArrayList<Target> targets {
            get {
                return this._targets;
            }
        }

        /**
         * Creates an empty Ruleset
         */
        public Ruleset() {
            this.rules = new Gee.ArrayList<Rule>();
            this.exclusions = new Gee.ArrayList<Regex>();
            this._targets = new Gee.ArrayList<Target>();
        }

        /**
         * Creates a Ruleset from a ruleset file
         */
        public Ruleset.from_xml(Xml.Node* root) throws RulesetError {
            this();
            if (root->name != "ruleset")
                throw new RulesetError.PARSE_ERROR("Name of rootnode must be 'ruleset'");

            // Set the Rulesets attributes
            string? n = root->get_prop("name");
            string? m;
            if (n != null)
                this.name = n;
            n = root->get_prop("default_off");
            this.default_off = n != null;
            n = root->get_prop("platform");
            if (n != null)
                this.platform = n;

            for (Xml.Node* cn = root->children; cn != null; cn = cn->next) {
                if (cn->type != Xml.ElementType.ELEMENT_NODE)
                    continue;
                switch (cn->name) {
                    case "rule":
                        n = cn->get_prop("from");
                        m = cn->get_prop("to");
                        if (n == null || m == null)
                            warning("Skipped malformed rule");
                        else
                            this.add_rule(n,m);
                        break;
                    case "target":
                        n = cn->get_prop("host");
                        if (n != null)
                            this.add_target(n);
                        else
                            warning("Skipped malformed target");
                        break;
                    case "exclusion":
                        n = cn->get_prop("pattern");
                        if (n != null)
                            this.add_exclusion(n);
                        else
                            warning("Skipped malformed exclusion");
                        break;
                    case "securecookie":
                        n = cn->get_prop("host");
                        if (n != null)
                            this.securecookie =  n;
                        else
                            warning("Skipped malformed securecookie");
                        break;
                    case "test":
                        // TODO: implement
                        break;
                    default:
                        warning("Unknown node found: %s".printf(cn->name));
                        break;
                }
            }
        }

        /**
         * Add a rewrite rule to this Ruleset
         * the parameters "from" and "to" should be valid regexes
         */
        public void add_rule(string from, string to) {
            this.rules.add(new Rule(from, to));
        }

        /**
         * Add an exclusion to this Ruleset
         */
        public void add_exclusion(string exclusion) {
            try {
                var exc_regex = new Regex(exclusion);
                this.exclusions.add(exc_regex);
            } catch (GLib.RegexError e) {
                warning("Could not add %s to exclusions", exclusion);
            }
        }

        /**
         * Add a target host to this Ruleset
         */
        public void add_target(string host) {
            this._targets.add(new Target(host));
        }

        /**
         * Rewrite an URL from HTTP to HTTPS
         */
        public string rewrite(string url) {
            // Skip if this rule is inactive
            if (this.default_off){
                return url;
            }

            // Skip if the given url matches any exclusions
            foreach (Regex exc in this.exclusions) {
                if (exc.match(url, 0))
                    return url;
            }

            // Rewrite the url by the given rules
            string u = url;
            foreach (Rule rule in this.rules) {
                u = rule.rewrite(u);
            }
            return u;
        }
    }

    /**
     * This class represents a rewrite rule
     * Rewrite rules consist of a from-regex and a to-string
     */
    private class Rule : GLib.Object {
        private Regex obsolete_placeholders;
        private Regex? from;
        private string to = "";

        /**
         * Create a new rule from a from-string and a to-string
         * the from string should be a valid regex
         */
        public Rule (string from, string to) {
            try {
                this.from = new Regex(from);
            } catch (GLib.RegexError e) {
                warning("Invalid from-regex in rule: %s",from);
                this.from = null;
            }
            this.to = to;
            this.obsolete_placeholders = /\$\d/;
        }

        /**
         * Turns a HTTP-URL into an appropriate HTTPS-URL
         */
        public string rewrite(string url) {
            if (this.from == null)
                return url;
            MatchInfo info;
            if (this.from.match(url, 0, out info)) {
                var suffix = url.replace(info.fetch(0), "");
                string ret = this.to;
                if (info.get_match_count() > 1) {
                    for (int i = 1; i < info.get_match_count(); i++) {
                        ret = ret.replace("$%d".printf(i),info.fetch(i));
                    }
                    ret += suffix;
                }
                if (info.get_match_count() == 1) {
                    ret = url.replace(info.fetch(0), this.to);
                    // Remove unused $-placeholders
                    ret = string.joinv("", this.obsolete_placeholders.split(ret));
                }
                return ret;
            } else
                return url;
        }
    }

    /**
     * Use Targets to check if a Ruleset applies to an arbitrary URL
     */
    public class Target : GLib.Object {
        public string host {get;set;default="";}
        private Regex? wildcardcheck;

        /**
         * Defines a new Target. Hosts of targets are only allowed to have one
         * asterisk as a wildcard-symbol
         */
        public Target(string host) {
            this.host = host;
            if (count_char(host,'*') > 1) {
                warning("Ignoring host %s. Contains more than one wildcard.".printf(host));
                return;
            }
            string escaped = Regex.escape_string(host);
            escaped = escaped.replace("""\*""", ".*");
            try {
                this.wildcardcheck = new Regex(escaped);
            } catch (GLib.RegexError e) {}
        }

        /**
         * This method checks if this target is applying to the given url
         */
        public bool matches(string url) {
            if (this.wildcardcheck == null) {
                warning("Tried to check invalid host: %s".printf(this.host));
                return false;
            }
            return this.wildcardcheck.match(url);
        }
    }

    private uint count_char(string s, unichar x) {
        uint r = 0;
        for (int i = 0; i < s.char_count(); i++) {
            if (s.get_char(i) == x)
                r++;
        }
        return r;
    }

}
