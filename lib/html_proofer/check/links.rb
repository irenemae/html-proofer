# frozen_string_literal: true

class HTMLProofer::Check::Links < HTMLProofer::Check
  include HTMLProofer::Utils

  def missing_link?
    missing_href? || missing_src?
  end

  def missing_href?
    anchor_tag? && blank?(@link.node['href'])
  end

  def missing_src?
    source_tag? && blank?(@link.node['src'])
  end

  def run
    @html.css('a, link, source').each do |node|
      @link = create_element(node)
      line = node.line
      content = node.content

      next if @link.ignore?

      # next if placeholder?

      if !allow_hash_href? && @link.node['href'] == '#'
        add_issue('linking to internal hash #, which points to nowhere', line: line, content: content)
        next
      end

      # is it even a valid URL?
      unless @link.url.valid?
        add_issue("#{@link.href} is an invalid URL", line: line, content: content)
        next
      end

      check_schemes(line, content)

      # is there even an href?
      if missing_link?
        next if missing_href? && allow_missing_href?

        # HTML5 allows dropping the href: http://git.io/vBX0z
        next if @html.internal_subset.nil? || (@html.internal_subset.name == 'html' && @html.internal_subset.external_id.nil?)

        add_issue('anchor has no href attribute', line: line, content: content)
        next
      end

      # intentionally here because we still want valid? & missing_href? to execute
      next if @link.url.non_http_remote?

      if !@link.node['href']&.start_with?('#') && !@link.url.internal? && @link.url.remote?
        check_sri(line, content) if @runner.check_sri? && node.name == 'link'
        # we need to skip these for now; although the domain main be valid,
        # curl/Typheous inaccurately return 404s for some links. cc https://git.io/vyCFx
        next if @link.node['rel'] == 'dns-prefetch'

        unless @link.url.path?
          add_issue("#{@link.url.raw_attribute} is an invalid URL", line: line, content: content)
          next
        end

        add_to_external_urls(@link.url, line)
      elsif @link.url.internal?
        # TODO: cache stuff should go here
        validator = HTMLProofer::UrlValidator::Internal.new(@runner, @link.url)

        unless validator.file_exists?
          add_issue("internally linking to #{@link.url.raw_attribute}, which does not exist", line: line, content: content)
          next
        end

        # does the local directory have a trailing slash?
        add_issue("internally linking to a directory #{@link.url.raw_attribute} without trailing slash", line: line, content: content) if validator.unslashed_directory?

        # add_to_internal_urls(@link.url, line)
        add_issue("internally linking to #{@link.url.raw_attribute}; the file exists, but the hash does not", line: line, content: content) unless validator.hash_exists?
      end
    end

    external_urls
  end

  def allow_missing_href?
    @runner.options[:allow_missing_href]
  end

  def allow_hash_href?
    @runner.options[:allow_hash_href]
  end

  def check_schemes(line, content)
    case @link.url.scheme
    when 'mailto'
      handle_mailto(line, content)
    when 'tel'
      handle_tel(line, content)
    when 'http'
      return unless @runner.options[:enforce_https]

      add_issue("#{@link.url.raw_attribute} is not an HTTPS link", line: line, content: content)
    end
  end

  def handle_mailto(line, content)
    if @link.url.path.empty?
      add_issue("#{@link.url.raw_attribute} contains no email address", line: line, content: content) unless ignore_empty_mailto?
    elsif !/#{URI::MailTo::EMAIL_REGEXP}/o.match?(@link.url.path)
      add_issue("#{@link.url.raw_attribute} contains an invalid email address", line: line, content: content)
    end
  end

  def handle_tel(line, content)
    add_issue("#{@link.url.raw_attribute} contains no phone number", line: line, content: content) if @link.url.path.empty?
  end

  def external_link_check(line, content)
    if link.url.exists? # rubocop:disable Style/GuardClause
      target_html = create_nokogiri(link.absolute_path)
      return add_issue("linking to #{link.href}, but #{link.hash} does not exist", line: line, content: content) unless hash_exists?(target_html, link.hash)
    else
      return add_issue("trying to find hash of #{link.href}, but #{link.absolute_path} does not exist", line: line, content: content)
    end

    true
  end

  def ignore_empty_mailto?
    @runner.options[:ignore_empty_mailto]
  end

  # Whitelist for affected elements from Subresource Integrity specification
  # https://w3c.github.io/webappsec-subresource-integrity/#link-element-for-stylesheets
  SRI_REL_TYPES = %(stylesheet)

  def check_sri(line, content)
    return unless SRI_REL_TYPES.include?(@link.node['rel'])

    if blank?(@link.node['integrity']) && blank?(@link.node['crossorigin'])
      add_issue("SRI and CORS not provided in: #{@link.url.raw_attribute}", line: line, content: content)
    elsif blank?(@link.node['integrity'])
      add_issue("Integrity is missing in: #{@link.url.raw_attribute}", line: line, content: content)
    elsif blank?(@link.node['crossorigin'])
      add_issue("CORS not provided for external resource in: #{@link.link.url.raw_attribute}", line: line, content: content)
    end
  end

  private def source_tag?
    @link.node.name == 'source'
  end

  private def anchor_tag?
    @link.node.name == 'a'
  end
end
