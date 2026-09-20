# frozen_string_literal: true

require 'ruby_llm'
require 'security_box'

RubyLLM.configure do |config|
  config.openrouter_api_key = ENV.fetch('OPENROUTER_API_KEY')
end

# Using read_only mode
SecurityBox.register(:read_only) do |config|
  config.mount './data/' => '/data'
end

# Using read_write mode
SecurityBox.register(:read_write) do |config|
  config.mount_rw './data/' => '/data'
end

class SecureExecution < RubyLLM::Tool
  description 'Execute Ruby\'s code on a sandbox.'

  def initialize(sb_profile:)
    @box = SecurityBox.spawn(sb_profile)
  end

  def execute(code:)
    puts "=> Calling tool:\n#{code}"
    value = box.eval(code).to_h
    puts "<="
    p value
  end

  private

  attr_reader :box
end

chat = RubyLLM.chat(model: 'deepseek/deepseek-v4-flash-0731', provider: :openrouter)

# Using the tool with read_only mode for ./data
chat = chat.with_tools(SecureExecution.new(sb_profile: :read_only))

puts chat.ask('Resume all files on folder /data').content
# Here's a summary of the contents of the `/data` folder:                                                                                                                                                                                           18:16 [54/651]
#
# ## Files in `/data`
#
# There is only **1 file** in the folder:
#
# ### 📄 `test.md` (25 bytes)
#
# A Markdown file containing:
# - **Heading:** `# This a Test`
# - **Body:** `1 2 3 4 5`
# - **Structure:** 2 lines
#
# ```
# # This a Test
#
# 1 2 3 4 5
# ```

puts chat.ask('Write this on resume.md on this folder').content
# ## ⚠️ Write blocked — `/data` is read-only
#
# | Operation | Result |
# |---|---|
# | Create `/data/resume.md` | ❌ `Errno::EPERM: Operation not permitted` |
# | Create a probe file (`.write_test`) | ❌ `Errno::EPERM` |
# | Append to existing `/data/test.md` | ❌ `Errno::EPERM` |
#
# The directory itself is mounted with **no write permission bits** (`mode 40000`), meaning the environment disallows any modification [...]

# Using the tool with read_write mode for ./data
chat = chat.with_tools(SecureExecution.new(sb_profile: :read_write))

puts chat.ask('Try again').content
## ✅ Done
#
# **Created:** `/data/resume.md` (verified by reading it back)
#
# **Contents of `/data` now:**
# - `test.md` (the original 25-byte test file)
# - `resume.md` (new — the directory summary)

# The file contains a Markdown summary of `/data`:
# - **Files:** notes that there is 1 file (`test.md`) with its content structure
# - **Conclusion:** describes `/data` as containing a single small Markdown test file with no subfolders

# Everything is written and verified. 🎉

