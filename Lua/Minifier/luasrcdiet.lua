#!/usr/bin/env lua
---------
-- LuaSrcDiet
--
-- Compresses Lua source code by removing unnecessary characters.
-- For Lua 5.1+ source code.
--
-- **Notes:**
--
-- * Remember to update version and date information below (MSG_TITLE).
-- * TODO: passing data tables around is a horrific mess.
-- * TODO: to implement pcall() to properly handle lexer etc. errors.
-- * TODO: need some automatic testing for a semblance of sanity.
-- * TODO: the plugin module is highly experimental and unstable.
----

package.path = package.path .. ";../Lua/Minifier/?.lua"

local fs = require "fs"
local llex = require "llex"
local lparser = require "lparser"
local luasrcdiet = require "init"
local optlex = require "optlex"
local optparser = require "optparser"

local byte = string.byte
local concat = table.concat
local find = string.find
local fmt = string.format
local gmatch = string.gmatch
local match = string.match
local print = print
local rep = string.rep
local sub = string.sub

local plugin

local LUA_VERSION = match(_VERSION, " (5%.[123])$") or "5.1"

-- Is --opt-binequiv available for this Lua version?
local BIN_EQUIV_AVAIL = LUA_VERSION == "5.1" and not package.loaded.jit


---------------------- Messages and textual data ----------------------

local MSG_TITLE = fmt([[
LuaSrcDiet: Puts your Lua 5.1+ source code on a diet
Version %s <%s>
]], luasrcdiet._VERSION, luasrcdiet._HOMEPAGE)

local MSG_USAGE = [[
usage: luasrcdiet [options] [filenames]

example:
  >luasrcdiet myscript.lua -o myscript_.lua

options:
  -v, --version       prints version information
  -h, --help          prints usage information
  -o <file>           specify file name to write output
  -s <suffix>         suffix for output files (default '_')
  --keep <msg>        keep block comment with <msg> inside
  --plugin <module>   run <module> in plugin/ directory
  -                   stop handling arguments

  (optimization levels)
  --none              all optimizations off (normalizes EOLs only)
  --basic             lexer-based optimizations only
  --maximum           maximize reduction of source

  (informational)
  --quiet             process files quietly
  --read-only         read file and print token stats only
  --dump-lexer        dump raw tokens from lexer to stdout
  --dump-parser       dump variable tracking tables from parser
  --details           extra info (strings, numbers, locals)

features (to disable, insert 'no' prefix like --noopt-comments):
%s
default settings:
%s]]

-- Optimization options, for ease of switching on and off.
--
-- * Positive to enable optimization, negative (no) to disable.
-- * These options should follow --opt-* and --noopt-* style for now.
local OPTION = [[
--opt-comments,'remove comments and block comments'
--opt-whitespace,'remove whitespace excluding EOLs'
--opt-emptylines,'remove empty lines'
--opt-eols,'all above, plus remove unnecessary EOLs'
--opt-strings,'optimize strings and long strings'
--opt-numbers,'optimize numbers'
--opt-locals,'optimize local variable names'
--opt-entropy,'tries to reduce symbol entropy of locals'
--opt-srcequiv,'insist on source (lexer stream) equivalence'
--opt-binequiv,'insist on binary chunk equivalence (only for PUC Lua 5.1)'
--opt-experimental,'apply experimental optimizations'
]]

-- Preset configuration.
local DEFAULT_CONFIG = [[
  --opt-comments --opt-whitespace --opt-emptylines
  --opt-numbers --opt-locals
  --opt-srcequiv --noopt-binequiv
]]
-- Override configurations: MUST explicitly enable/disable everything.
local BASIC_CONFIG = [[
  --opt-comments --opt-whitespace --opt-emptylines
  --noopt-eols --noopt-strings --noopt-numbers
  --noopt-locals --noopt-entropy
  --opt-srcequiv --noopt-binequiv
]]
local MAXIMUM_CONFIG = [[
  --opt-comments --opt-whitespace --opt-emptylines
  --opt-eols --opt-strings --opt-numbers
  --opt-locals --opt-entropy
  --opt-srcequiv
]] .. (BIN_EQUIV_AVAIL and ' --opt-binequiv' or ' --noopt-binequiv')

local NONE_CONFIG = [[
  --noopt-comments --noopt-whitespace --noopt-emptylines
  --noopt-eols --noopt-strings --noopt-numbers
  --noopt-locals --noopt-entropy
  --opt-srcequiv --noopt-binequiv
]]

local DEFAULT_SUFFIX = "_"      -- default suffix for file renaming
local PLUGIN_SUFFIX = "luasrcdiet.plugin." -- relative location of plugins


------------- Startup and initialize option list handling -------------

--- Simple error message handler; change to error if traceback wanted.
--
-- @tparam string msg The message to print.
local function die(msg)
  print("LuaSrcDiet (error): "..msg); os.exit(1)
end
--die = error--DEBUG

-- Prepare text for list of optimizations, prepare lookup table.
local MSG_OPTIONS = ""
do
  local WIDTH = 24
  local o = {}
  for op, desc in gmatch(OPTION, "%s*([^,]+),'([^']+)'") do
    local msg = "  "..op
    msg = msg..rep(" ", WIDTH - #msg)..desc.."\n"
    MSG_OPTIONS = MSG_OPTIONS..msg
    o[op] = true
    o["--no"..sub(op, 3)] = true
  end
  OPTION = o  -- replace OPTION with lookup table
end

MSG_USAGE = fmt(MSG_USAGE, MSG_OPTIONS, DEFAULT_CONFIG)


--------- Global variable initialization, option set handling ---------

local suffix = DEFAULT_SUFFIX           -- file suffix
local option = {}                       -- program options
local stat_c, stat_l                    -- statistics tables

--- Sets option lookup table based on a text list of options.
--
-- Note: additional forced settings for --opt-eols is done in optlex.lua.
--
-- @tparam string CONFIG
local function set_options(CONFIG)
  for op in gmatch(CONFIG, "(%-%-%S+)") do
    if sub(op, 3, 4) == "no" and        -- handle negative options
       OPTION["--"..sub(op, 5)] then
      option[sub(op, 5)] = false
    else
      option[sub(op, 3)] = true
    end
  end
end


-------------------------- Support functions --------------------------

-- List of token types, parser-significant types are up to TTYPE_GRAMMAR
-- while the rest are not used by parsers; arranged for stats display.
local TTYPES = {
  "TK_KEYWORD", "TK_NAME", "TK_NUMBER",         -- grammar
  "TK_STRING", "TK_LSTRING", "TK_OP",
  "TK_EOS",
  "TK_COMMENT", "TK_LCOMMENT",                  -- non-grammar
  "TK_EOL", "TK_SPACE",
}
local TTYPE_GRAMMAR = 7

local EOLTYPES = {                      -- EOL names for token dump
  ["\n"] = "LF", ["\r"] = "CR",
  ["\n\r"] = "LFCR", ["\r\n"] = "CRLF",
}

--- Reads source code from the file.
--
-- @tparam string fname Path of the file to read.
-- @treturn string Content of the file.
local function load_file(fname)
  local data, err = fs.read_file(fname, "rb")
  if not data then die(err) end
  return data
end

--- Saves source code to the file.
--
-- @tparam string fname Path of the destination file.
-- @tparam string dat The data to write into the file.
local function save_file(fname, dat)
  local ok, err = fs.write_file(fname, dat, "wb")
  if not ok then die(err) end
end


------------------ Functions to deal with statistics ------------------

--- Initializes the statistics table.
local function stat_init()
  stat_c, stat_l = {}, {}
  for i = 1, #TTYPES do
    local ttype = TTYPES[i]
    stat_c[ttype], stat_l[ttype] = 0, 0
  end
end

--- Adds a token to the statistics table.
--
-- @tparam string tok The token.
-- @param seminfo
local function stat_add(tok, seminfo)
  stat_c[tok] = stat_c[tok] + 1
  stat_l[tok] = stat_l[tok] + #seminfo
end

--- Computes totals for the statistics table, returns average table.
--
-- @treturn table
local function stat_calc()
  local function avg(c, l)                      -- safe average function
    if c == 0 then return 0 end
    return l / c
  end
  local stat_a = {}
  local c, l = 0, 0
  for i = 1, TTYPE_GRAMMAR do                   -- total grammar tokens
    local ttype = TTYPES[i]
    c = c + stat_c[ttype]; l = l + stat_l[ttype]
  end
  stat_c.TOTAL_TOK, stat_l.TOTAL_TOK = c, l
  stat_a.TOTAL_TOK = avg(c, l)
  c, l = 0, 0
  for i = 1, #TTYPES do                         -- total all tokens
    local ttype = TTYPES[i]
    c = c + stat_c[ttype]; l = l + stat_l[ttype]
    stat_a[ttype] = avg(stat_c[ttype], stat_l[ttype])
  end
  stat_c.TOTAL_ALL, stat_l.TOTAL_ALL = c, l
  stat_a.TOTAL_ALL = avg(c, l)
  return stat_a
end


----------------------------- Main tasks -----------------------------

--- A simple token dumper, minimal translation of seminfo data.
--
-- @tparam string srcfl Path of the source file.
local function dump_tokens(srcfl)
  -- Load file and process source input into tokens.
  local z = load_file(srcfl)
  local toklist, seminfolist = llex.lex(z)

  -- Display output.
  for i = 1, #toklist do
    local tok, seminfo = toklist[i], seminfolist[i]
    if tok == "TK_OP" and byte(seminfo) < 32 then
      seminfo = "("..byte(seminfo)..")"
    elseif tok == "TK_EOL" then
      seminfo = EOLTYPES[seminfo]
    else
      seminfo = "'"..seminfo.."'"
    end
    print(tok.." "..seminfo)
  end--for
end

--- Dumps globalinfo and localinfo tables.
--
-- @tparam string srcfl Path of the source file.
local function dump_parser(srcfl)
  -- Load file and process source input into tokens,
  local z = load_file(srcfl)
  local toklist, seminfolist, toklnlist = llex.lex(z)

  -- Do parser optimization here.
  local xinfo = lparser.parse(toklist, seminfolist, toklnlist)
  local globalinfo, localinfo = xinfo.globalinfo, xinfo.localinfo

  -- Display output.
  local hl = rep("-", 72)
  print("*** Local/Global Variable Tracker Tables ***")
  print(hl.."\n GLOBALS\n"..hl)
  -- global tables have a list of xref numbers only
  for i = 1, #globalinfo do
    local obj = globalinfo[i]
    local msg = "("..i..") '"..obj.name.."' -> "
    local xref = obj.xref
    for j = 1, #xref do msg = msg..xref[j].." " end
    print(msg)
  end
  -- Local tables have xref numbers and a few other special
  -- numbers that are specially named: decl (declaration xref),
  -- act (activation xref), rem (removal xref).
  print(hl.."\n LOCALS (decl=declared act=activated rem=removed)\n"..hl)
  for i = 1, #localinfo do
    local obj = localinfo[i]
    local msg = "("..i..") '"..obj.name.."' decl:"..obj.decl..
                " act:"..obj.act.." rem:"..obj.rem
    if obj.is_special then
      msg = msg.." is_special"
    end
    msg = msg.." -> "
    local xref = obj.xref
    for j = 1, #xref do msg = msg..xref[j].." " end
    print(msg)
  end
  print(hl.."\n")
end

--- Reads source file(s) and reports some statistics.
--
-- @tparam string srcfl Path of the source file.
local function read_only(srcfl)
  -- Load file and process source input into tokens.
  local z = load_file(srcfl)
  local toklist, seminfolist = llex.lex(z)
  print(MSG_TITLE)
  print("Statistics for: "..srcfl.."\n")

  -- Collect statistics.
  stat_init()
  for i = 1, #toklist do
    local tok, seminfo = toklist[i], seminfolist[i]
    stat_add(tok, seminfo)
  end--for
  local stat_a = stat_calc()

  -- Display output.
  local function figures(tt)
    return stat_c[tt], stat_l[tt], stat_a[tt]
  end
  local tabf1, tabf2 = "%-16s%8s%8s%10s", "%-16s%8d%8d%10.2f"
  local hl = rep("-", 42)
  print(fmt(tabf1, "Lexical",  "Input", "Input", "Input"))
  print(fmt(tabf1, "Elements", "Count", "Bytes", "Average"))
  print(hl)
  for i = 1, #TTYPES do
    local ttype = TTYPES[i]
    print(fmt(tabf2, ttype, figures(ttype)))
    if ttype == "TK_EOS" then print(hl) end
  end
  print(hl)
  print(fmt(tabf2, "Total Elements", figures("TOTAL_ALL")))
  print(hl)
  print(fmt(tabf2, "Total Tokens", figures("TOTAL_TOK")))
  print(hl.."\n")
end

--- Processes source file(s), writes output and reports some statistics.
--
-- @tparam string srcfl Path of the source file.
-- @tparam string destfl Path of the destination file where to write optimized source.
local function process_file(srcfl, destfl)
  -- handle quiet option
  local function print(...)  --luacheck: ignore 431
    if option.QUIET then return end
    _G.print(...)
  end
  if plugin and plugin.init then        -- plugin init
    option.EXIT = false
    plugin.init(option, srcfl, destfl)
    if option.EXIT then return end
  end
  print(MSG_TITLE)                      -- title message

  -- Load file and process source input into tokens.
  local z = load_file(srcfl)
  if plugin and plugin.post_load then   -- plugin post-load
    z = plugin.post_load(z) or z
    if option.EXIT then return end
  end
  local toklist, seminfolist, toklnlist = llex.lex(z)
  if plugin and plugin.post_lex then    -- plugin post-lex
    plugin.post_lex(toklist, seminfolist, toklnlist)
    if option.EXIT then return end
  end

  -- Collect 'before' statistics.
  stat_init()
  for i = 1, #toklist do
    local tok, seminfo = toklist[i], seminfolist[i]
    stat_add(tok, seminfo)
  end--for
  local stat1_a = stat_calc()
  local stat1_c, stat1_l = stat_c, stat_l

  -- Do parser optimization here.
  optparser.print = print  -- hack
  local xinfo = lparser.parse(toklist, seminfolist, toklnlist)
  if plugin and plugin.post_parse then          -- plugin post-parse
    plugin.post_parse(xinfo.globalinfo, xinfo.localinfo)
    if option.EXIT then return end
  end
  optparser.optimize(option, toklist, seminfolist, xinfo)
  if plugin and plugin.post_optparse then       -- plugin post-optparse
    plugin.post_optparse()
    if option.EXIT then return end
  end

  -- Do lexer optimization here, save output file.
  local warn = optlex.warn  -- use this as a general warning lookup
  optlex.print = print  -- hack
  toklist, seminfolist, toklnlist
    = optlex.optimize(option, toklist, seminfolist, toklnlist)
  if plugin and plugin.post_optlex then         -- plugin post-optlex
    plugin.post_optlex(toklist, seminfolist, toklnlist)
    if option.EXIT then return end
  end
  local dat = concat(seminfolist)
  -- Depending on options selected, embedded EOLs in long strings and
  -- long comments may not have been translated to \n, tack a warning.
  if find(dat, "\r\n", 1, 1) or
     find(dat, "\n\r", 1, 1) then
    warn.MIXEDEOL = true
  end

  -- Save optimized source stream to output file.
  save_file(destfl, dat)

  -- Collect 'after' statistics.
  stat_init()
  for i = 1, #toklist do
    local tok, seminfo = toklist[i], seminfolist[i]
    stat_add(tok, seminfo)
  end--for
  local stat_a = stat_calc()

  -- Display output.
  print("Statistics for: "..srcfl.." -> "..destfl.."\n")
  local function figures(tt)
    return stat1_c[tt], stat1_l[tt], stat1_a[tt],
           stat_c[tt],  stat_l[tt],  stat_a[tt]
  end
  local tabf1, tabf2 = "%-16s%8s%8s%10s%8s%8s%10s",
                       "%-16s%8d%8d%10.2f%8d%8d%10.2f"
  local hl = rep("-", 68)
  print("*** lexer-based optimizations summary ***\n"..hl)
  print(fmt(tabf1, "Lexical",
            "Input", "Input", "Input",
            "Output", "Output", "Output"))
  print(fmt(tabf1, "Elements",
            "Count", "Bytes", "Average",
            "Count", "Bytes", "Average"))
  print(hl)
  for i = 1, #TTYPES do
    local ttype = TTYPES[i]
    print(fmt(tabf2, ttype, figures(ttype)))
    if ttype == "TK_EOS" then print(hl) end
  end
  print(hl)
  print(fmt(tabf2, "Total Elements", figures("TOTAL_ALL")))
  print(hl)
  print(fmt(tabf2, "Total Tokens", figures("TOTAL_TOK")))
  print(hl)

  -- Report warning flags from optimizing process.
  if warn.LSTRING then
    print("* WARNING: "..warn.LSTRING)
  elseif warn.MIXEDEOL then
    print("* WARNING: ".."output still contains some CRLF or LFCR line endings")
  elseif warn.SRC_EQUIV then
    print("* WARNING: "..smsg)
  elseif warn.BIN_EQUIV then
    print("* WARNING: "..bmsg)
  end
  print()
end


---------------------------- Main functions ---------------------------

local arg = {...}  -- program arguments
set_options(DEFAULT_CONFIG)     -- set to default options at beginning

--- Does per-file handling, ship off to tasks.
--
-- @tparam {string,...} fspec List of source files.
local function do_files(fspec)
  for i = 1, #fspec do
    local srcfl = fspec[i]
    local destfl

    -- Find and replace extension for filenames.
    local extb, exte = find(srcfl, "%.[^%.%\\%/]*$")
    local basename, extension = srcfl, ""
    if extb and extb > 1 then
      basename = sub(srcfl, 1, extb - 1)
      extension = sub(srcfl, extb, exte)
    end
    destfl = basename..suffix..extension
    if #fspec == 1 and option.OUTPUT_FILE then
      destfl = option.OUTPUT_FILE
    end
    if srcfl == destfl then
      die("output filename identical to input filename")
    end

    -- Perform requested operations.
    if option.DUMP_LEXER then
      dump_tokens(srcfl)
    elseif option.DUMP_PARSER then
      dump_parser(srcfl)
    elseif option.READ_ONLY then
      read_only(srcfl)
    else
      process_file(srcfl, destfl)
    end
  end--for
end

--- The main function.
local function main()
  local fspec = {}
  local argn, i = #arg, 1
  if argn == 0 then
    option.HELP = true
  end

  -- Handle arguments.
  while i <= argn do
    local o, p = arg[i], arg[i + 1]
    local dash = match(o, "^%-%-?")
    if dash == "-" then                 -- single-dash options
      if o == "-h" then
        option.HELP = true; break
      elseif o == "-v" then
        option.VERSION = true; break
      elseif o == "-s" then
        if not p then die("-s option needs suffix specification") end
        suffix = p
        i = i + 1
      elseif o == "-o" then
        if not p then die("-o option needs a file name") end
        option.OUTPUT_FILE = p
        i = i + 1
      elseif o == "-" then
        break -- ignore rest of args
      else
        die("unrecognized option "..o)
      end
    elseif dash == "--" then            -- double-dash options
      if o == "--help" then
        option.HELP = true; break
      elseif o == "--version" then
        option.VERSION = true; break
      elseif o == "--keep" then
        if not p then die("--keep option needs a string to match for") end
        option.KEEP = p
        i = i + 1
      elseif o == "--plugin" then
        if not p then die("--plugin option needs a module name") end
        if option.PLUGIN then die("only one plugin can be specified") end
        option.PLUGIN = p
        plugin = require(PLUGIN_SUFFIX..p)
        i = i + 1
      elseif o == "--quiet" then
        option.QUIET = true
      elseif o == "--read-only" then
        option.READ_ONLY = true
      elseif o == "--basic" then
        set_options(BASIC_CONFIG)
      elseif o == "--maximum" then
        set_options(MAXIMUM_CONFIG)
      elseif o == "--none" then
        set_options(NONE_CONFIG)
      elseif o == "--dump-lexer" then
        option.DUMP_LEXER = true
      elseif o == "--dump-parser" then
        option.DUMP_PARSER = true
      elseif o == "--details" then
        option.DETAILS = true
      elseif OPTION[o] then  -- lookup optimization options
        set_options(o)
      else
        die("unrecognized option "..o)
      end
    else
      fspec[#fspec + 1] = o             -- potential filename
    end
    i = i + 1
  end--while
  if option.HELP then
    print(MSG_TITLE..MSG_USAGE); return true
  elseif option.VERSION then
    print(MSG_TITLE); return true
  end
  if option["opt-binequiv"] and not BIN_EQUIV_AVAIL then
    die("--opt-binequiv is available only for PUC Lua 5.1!")
  end
  if #fspec > 0 then
    if #fspec > 1 and option.OUTPUT_FILE then
      die("with -o, only one source file can be specified")
    end
    do_files(fspec)
    return true
  else
    die("nothing to do!")
  end
end

-- entry point -> main() -> do_files()
if not main() then
  die("Please run with option -h or --help for usage information")
end
