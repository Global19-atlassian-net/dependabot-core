# frozen_string_literal: true

require "excon"
require "nokogiri"

require "dependabot/nuget/version"
require "dependabot/nuget/requirement"
require "dependabot/nuget/update_checker"
require "dependabot/shared_helpers"

module Dependabot
  module Nuget
    class UpdateChecker
      class VersionFinder
        require_relative "repository_finder"

        NUGET_RANGE_REGEX = /[\(\[].*,.*[\)\]]/.freeze

        def initialize(dependency:, dependency_files:, credentials:,
                       ignored_versions:, raise_on_ignored: false,
                       security_advisories:)
          @dependency          = dependency
          @dependency_files    = dependency_files
          @credentials         = credentials
          @ignored_versions    = ignored_versions
          @raise_on_ignored    = raise_on_ignored
          @security_advisories = security_advisories
        end

        def latest_version_details
          @latest_version_details ||=
            begin
              possible_versions = versions
              possible_versions = filter_prereleases(possible_versions)
              possible_versions = filter_ignored_versions(possible_versions)
              possible_versions.max_by { |hash| hash.fetch(:version) }
            end
        end

        def lowest_security_fix_version_details
          @lowest_security_fix_version_details ||=
            begin
              possible_versions = versions
              possible_versions = filter_prereleases(possible_versions)
              possible_versions = filter_vulnerable_versions(possible_versions)
              possible_versions = filter_ignored_versions(possible_versions)
              possible_versions = filter_lower_versions(possible_versions)
              possible_versions.min_by { |hash| hash.fetch(:version) }
            end
        end

        def versions
          available_v3_versions + available_v2_versions
        end

        attr_reader :dependency, :dependency_files, :credentials,
                    :ignored_versions, :security_advisories

        private

        def filter_prereleases(possible_versions)
          possible_versions.reject do |d|
            version = d.fetch(:version)
            version.prerelease? && !related_to_current_pre?(version)
          end
        end

        def filter_ignored_versions(possible_versions)
          filtered = possible_versions

          ignored_versions.each do |req|
            ignore_req = requirement_class.new(parse_requirement_string(req))
            filtered =
              filtered.
              reject { |v| ignore_req.satisfied_by?(v.fetch(:version)) }
          end

          if @raise_on_ignored && filtered.empty? && possible_versions.any?
            raise AllVersionsIgnored
          end

          filtered
        end

        def filter_vulnerable_versions(possible_versions)
          versions_array = possible_versions

          security_advisories.each do |advisory|
            versions_array =
              versions_array.
              reject { |v| advisory.vulnerable?(v.fetch(:version)) }
          end

          versions_array
        end

        def filter_lower_versions(possible_versions)
          possible_versions.select do |v|
            v.fetch(:version) > version_class.new(dependency.version)
          end
        end

        def parse_requirement_string(string)
          return string if string.match?(NUGET_RANGE_REGEX)

          string.split(",").map(&:strip)
        end

        def available_v3_versions
          v3_nuget_listings.flat_map do |listing|
            listing.
              fetch("versions", []).
              map do |v|
                nuspec_url =
                  listing.fetch("listing_details").
                  fetch(:versions_url).
                  gsub(/index\.json$/, "#{v}/#{sanitized_name}.nuspec")

                {
                  version: version_class.new(v),
                  nuspec_url: nuspec_url,
                  source_url: nil,
                  repo_url:
                    listing.fetch("listing_details").fetch(:repository_url)
                }
              end
          end
        end

        def available_v2_versions
          v2_nuget_listings.flat_map do |listing|
            body = listing.fetch("xml_body", [])
            doc = Nokogiri::XML(body)
            doc.remove_namespaces!

            doc.xpath("/feed/entry").map do |entry|
              listed = entry.at_xpath("./properties/Listed")&.content&.strip
              next if listed&.casecmp("false")&.zero?

              entry_details = dependency_details_from_v2_entry(entry)
              entry_details.merge(
                repo_url: listing.fetch("listing_details").
                          fetch(:repository_url)
              )
            end.compact
          end
        end

        def dependency_details_from_v2_entry(entry)
          version = entry.at_xpath("./properties/Version").content.strip
          source_urls = []
          [
            entry.at_xpath("./properties/ProjectUrl")&.content,
            entry.at_xpath("./properties/ReleaseNotes")&.content
          ].compact.join(" ").scan(Source::SOURCE_REGEX) do
            source_urls << Regexp.last_match.to_s
          end

          source_url = source_urls.find { |url| Source.from_url(url) }
          source_url = Source.from_url(source_url)&.url if source_url

          {
            version: version_class.new(version),
            nuspec_url: nil,
            source_url: source_url
          }
        end

        # rubocop:disable Metrics/PerceivedComplexity
        def related_to_current_pre?(version)
          current_version = dependency.version
          if current_version &&
             version_class.correct?(current_version) &&
             version_class.new(current_version).prerelease? &&
             version_class.new(current_version).release == version.release
            return true
          end

          dependency.requirements.any? do |req|
            reqs = parse_requirement_string(req.fetch(:requirement) || "")
            next unless reqs.any? { |r| r.include?("-") }

            requirement_class.
              requirements_array(req.fetch(:requirement)).
              any? do |r|
                r.requirements.any? { |a| a.last.release == version.release }
              end
          rescue Gem::Requirement::BadRequirementError
            false
          end
        end

        # rubocop:enable Metrics/PerceivedComplexity

        def v3_nuget_listings
          return @v3_nuget_listings unless @v3_nuget_listings.nil?

          @v3_nuget_listings ||=
            dependency_urls.
            select { |details| details.fetch(:repository_type) == "v3" }.
            map do |url_details|
              versions = versions_for_v3_repository(url_details)
              next unless versions

              { "versions" => versions, "listing_details" => url_details }
            end.compact
        end

        def v2_nuget_listings
          return @v2_nuget_listings unless @v2_nuget_listings.nil?

          @v2_nuget_listings ||=
            dependency_urls.
            select { |details| details.fetch(:repository_type) == "v2" }.
            map do |url_details|
              response = Excon.get(
                url_details[:versions_url],
                headers: url_details[:auth_header],
                idempotent: true,
                **excon_defaults
              )
              next unless response.status == 200

              {
                "xml_body" => response.body,
                "listing_details" => url_details
              }
            end.compact
        end

        def versions_for_v3_repository(repository_details)
          # If we have a search URL that returns results we use it
          # (since it will exclude unlisted versions)
          if repository_details[:search_url]
            fetch_versions_from_search_url(repository_details)
          # Otherwise, use the versions URL
          elsif repository_details[:versions_url]
            response = Excon.get(
              repository_details[:versions_url],
              headers: repository_details[:auth_header],
              idempotent: true,
              **excon_defaults
            )
            return unless response.status == 200

            body = remove_wrapping_zero_width_chars(response.body)
            JSON.parse(body).fetch("versions")
          end
        end

        def fetch_versions_from_search_url(repository_details)
          response = Excon.get(
            repository_details[:search_url],
            headers: repository_details[:auth_header],
            idempotent: true,
            **excon_defaults
          )
          return unless response.status == 200

          body = remove_wrapping_zero_width_chars(response.body)
          JSON.parse(body).fetch("data").
            find { |d| d.fetch("id").casecmp(sanitized_name).zero? }&.
            fetch("versions")&.
            map { |d| d.fetch("version") }
        rescue Excon::Error::Timeout, Excon::Error::Socket
          repo_url = repository_details[:repository_url]
          raise if repo_url == RepositoryFinder::DEFAULT_REPOSITORY_URL

          raise PrivateSourceTimedOut, repo_url
        end

        def dependency_urls
          @dependency_urls ||=
            RepositoryFinder.new(
              dependency: dependency,
              credentials: credentials,
              config_files: nuget_configs
            ).dependency_urls
        end

        def nuget_configs
          @nuget_configs ||=
            dependency_files.select { |f| f.name.match?(/nuget\.config$/i) }
        end

        def sanitized_name
          dependency.name.downcase
        end

        def version_class
          Nuget::Version
        end

        def requirement_class
          Nuget::Requirement
        end

        def remove_wrapping_zero_width_chars(string)
          string.force_encoding("UTF-8").encode.
            gsub(/\A[\u200B-\u200D\uFEFF]/, "").
            gsub(/[\u200B-\u200D\uFEFF]\Z/, "")
        end

        def excon_defaults
          # For large JSON files we sometimes need a little longer than for
          # other languages. For example, see:
          # https://dotnet.myget.org/F/aspnetcore-dev/api/v3/query?
          # q=microsoft.aspnetcore.mvc&prerelease=true
          SharedHelpers.excon_defaults.merge(
            connect_timeout: 30,
            write_timeout: 30,
            read_timeout: 30
          )
        end
      end
    end
  end
end
