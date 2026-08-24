# frozen_string_literal: true

module Imports
  module BulkInsertable
    extend ActiveSupport::Concern

    private

    def bulk_insert_points(batch)
      return 0 if batch.empty?
      
      # --- NEW: Delete overlaps for the current batch ---
      times = batch.map { |r| r[:timestamp] }.compact
      if times.any?
        # 1. Fetch the overlapping point IDs for this specific user
        point_ids = Point.where(user_id: user_id, timestamp: times.min..times.max).pluck(:id)

        if point_ids.any?
          # Mirror your BULK_DESTROY_MAX constant rule if you want the same constraint
          # Define this constant at the top of your class or replace with your hardcoded value (e.g., 5000)
          bulk_destroy_max = 5000
          
          # Optional guard check: slice into batches if you exceed the controller limit, 
          # or process it in chunks using point_ids.each_slice(bulk_destroy_max)
          if point_ids.size > bulk_destroy_max
            Rails.logger.warn "[#{importer_name} Importer] Large cleanup required: #{point_ids.size} points exceeds safety limit. Slicing execution."
          end

          affected_track_ids = nil
          destroyed = nil

          # 2. Database transaction blocks execution until finished (Synchronous)
          ActiveRecord::Base.transaction do
            affected_track_ids = Point.where(user_id: user_id, id: point_ids)
                                      .where.not(track_id: nil)
                                      .distinct
                                      .pluck(:track_id)
                                      
            destroyed = Point.where(user_id: user_id, id: point_ids).destroy_all
          end

          deleted_count = destroyed.count

          if deleted_count.positive?
            # 3. Synchronously decrease user dashboard counts
            User.update_counters(user_id, points_count: -deleted_count)

            # 4. Extract unique Year/Month pairs to recalculate analytics dashboard
            destroyed
              .map { |p| Time.zone.at(p.timestamp) }
              .map { |ts| [ts.year, ts.month] }
              .uniq
              .each { |year, month| Stats::CalculatingJob.perform_later(user_id, year, month) }
          end

          # 5. Enqueue track length/speed corrections
          if affected_track_ids.any?
            Rails.logger.info(
              "[#{importer_name} Importer] Batch Cleanup deleted #{deleted_count} points, " \
              "enqueuing Tracks::RecalculateJob for #{affected_track_ids.size} tracks."
            )
            affected_track_ids.each { |track_id| Tracks::RecalculateJob.perform_later(track_id) }
          end
        end
      end
      # --------------------------------------------------

      compacted = batch.compact
      unique_batch = compacted
                     .reject { |record| Points::NullIsland.lonlat?(record[:lonlat]) }
                     .uniq { |record| [record[:lonlat], record[:timestamp], record[:user_id]] }
      zero_skipped = compacted.size - compacted.count { |r| !Points::NullIsland.lonlat?(r[:lonlat]) }
      Rails.logger.info("[#{importer_name}] skipped #{zero_skipped} Null Island (0,0) points") if zero_skipped.positive?
      return 0 if unique_batch.empty?

      dimension_resolver.stamp(unique_batch)

      result = Point.upsert_all(
        unique_batch,
        unique_by: %i[user_id timestamp lonlat],
        returning: Arel.sql('id'),
        on_duplicate: :skip
      )

      inserted = result.length
      skipped  = unique_batch.length - inserted
      record_batch_counters(unique_batch.length, skipped)

      if inserted.positive?
        Points::TileEpoch.bump(import.user_id, timestamps: unique_batch.map { |record| record[:timestamp] })
      end

      inserted
    rescue StandardError => e
      raise if atomic_bulk_insert?

      on_bulk_insert_error(e)
      create_import_error_notification("Failed to process #{importer_name} data: #{e.message}")
      0
    end

    # Memoised across batches: one import usually carries a single
    # device/importer combo, so the resolver's cache turns the whole run into
    # one lookup instead of one per batch.
    def dimension_resolver
      @dimension_resolver ||= Points::DimensionResolver.new
    end

    # Importers that wrap the whole import in a transaction override this to true, so an
    # insert failure propagates and rolls back cleanly instead of poisoning the transaction
    # (a swallowed error would leave the connection aborted for the notification write).
    def atomic_bulk_insert?
      false
    end

    def record_batch_counters(attempted, skipped)
      counters = { raw_points: attempted }
      counters[:doubles] = skipped if skipped.positive?
      Import.update_counters(import.id, counters)
    end

    def create_import_error_notification(message)
      I18n.with_locale(import.user.locale) do
        Notification.create!(
          user_id: import.user_id,
          title: I18n.t('services.imports.bulk_insertable.importer_name_import_error', importer_name: importer_name),
          content: message,
          kind: :error
        )
      end
    end

    # Override in subclasses to add custom error handling (e.g. ExceptionReporter)
    def on_bulk_insert_error(exception); end

    def importer_name
      self.class.name.split('::').first
    end
  end
end
