function [seedinfo_new, success, msg] = ncorr_seed_transform(seedinfo_ref, cx_ref, cy_ref, cx_new, cy_new, spacing, roi_mask_new)
% NCORR_SEED_TRANSFORM  Translate DIC seed positions to a new sample's ROI.
%
% Takes the seedinfo captured during the interactive setup run and shifts
% all seed pixel coordinates by the displacement between the two ROI
% centroids.  All displacement/gradient fields are zeroed so that
% ncorr_alg_dicanalysis treats these as fresh starting seeds.
%
% Inputs
%   seedinfo_ref  - struct array (num_thread x num_region x num_img) with
%                   fields: paramvector, num_region, num_thread, computepoints.
%                   Captured from handles_ncorr.data_dic.seedinfo after the
%                   setup run.
%   cx_ref, cy_ref - Centroid [x y] (column, row) of the SETUP sample ROI
%                   in full-resolution pixel coordinates (zero-based, ncorr).
%   cx_new, cy_new - Centroid [x y] of the CURRENT sample ROI.
%   spacing       - DIC subset spacing (integer), from batch_config.dic_params.spacing.
%   roi_mask_new  - logical mask (H x W) for the current sample ROI.
%
% Outputs
%   seedinfo_new  - struct array in same shape as seedinfo_ref, translated
%                   seed positions, zeroed displacements.  Ready for params_init.
%   success       - logical; true if ALL seeds are valid inside roi_mask_new.
%   msg           - char; human-readable status.
%
% See also ncorr_batch_run, ncorr_batch_setup

    success = false;
    msg = '';

    if isempty(seedinfo_ref)
        msg = 'seedinfo_ref is empty - run ncorr_batch_setup first.';
        seedinfo_new = struct('paramvector',{},'num_region',{},'num_thread',{},'computepoints',{});
        return;
    end

    delta_x = cx_new - cx_ref;
    delta_y = cy_new - cy_ref;

    seedinfo_new = seedinfo_ref;
    [n_threads, n_regions, n_imgs] = size(seedinfo_ref);

    for t = 1:n_threads
        for r = 1:n_regions
            for i = 1:n_imgs
                pv = seedinfo_ref(t, r, i).paramvector;
                % paramvector: [x y u v du/dx du/dy dv/dx dv/dy corrcoef]

                x_new = pv(1) + delta_x;
                y_new = pv(2) + delta_y;

                % Snap to spacing grid
                x_new = round(x_new / (spacing + 1)) * (spacing + 1);
                y_new = round(y_new / (spacing + 1)) * (spacing + 1);

                % Zero displacement/gradient/corrcoef
                new_pv = [x_new, y_new, 0, 0, 0, 0, 0, 0, 0];

                seedinfo_new(t, r, i).paramvector   = new_pv;
                seedinfo_new(t, r, i).computepoints = 0;
            end
        end
    end

    % Validate all seeds inside roi_mask_new
    [h, w] = size(roi_mask_new);
    all_valid = true;
    invalid_list = {};

    for t = 1:n_threads
        for r = 1:n_regions
            pv  = seedinfo_new(t, r, 1).paramvector;
            x   = pv(1);
            y   = pv(2);
            col = round(x) + 1;
            row = round(y) + 1;

            if col < 1 || col > w || row < 1 || row > h
                all_valid = false;
                invalid_list{end+1} = sprintf('thread %d region %d: [%.1f, %.1f] out of bounds [%d x %d]', ...
                                               t, r, x, y, w, h); %#ok<AGROW>
                continue;
            end

            if ~roi_mask_new(row, col)
                all_valid = false;
                invalid_list{end+1} = sprintf('thread %d region %d: [%.1f, %.1f] outside ROI', ...
                                               t, r, x, y); %#ok<AGROW>
            end
        end
    end

    if all_valid
        success = true;
        msg = sprintf('All %d seed(s) valid. Centroid shift: dx=%.1f dy=%.1f px.', ...
                      n_threads * n_regions, delta_x, delta_y);
    else
        msg = sprintf('Seed transform failed - %d invalid seed(s):\n  %s', ...
                      numel(invalid_list), strjoin(invalid_list, '\n  '));
        seedinfo_new = struct('paramvector',{},'num_region',{},'num_thread',{},'computepoints',{});
    end
end
