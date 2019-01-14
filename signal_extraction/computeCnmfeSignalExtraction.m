function [cnmfeAnalysisOutput] = computeCnmfeSignalExtraction(inputMovie,varargin)
    % Wrapper function for CNMF-E, update for most recent versions.
    % Building off of demo_large_data_1p.m in CNMF-E github repo
    % Most recent commit tested on: https://github.com/epnev/ca_source_extraction/commit/187bbdbe66bca466b83b81861b5601891a95b8d1
    % https://github.com/epnev/ca_source_extraction/blob/master/demo_script_class.m
    % Biafra Ahanonu
    % started: 2018.10.20 [16:38:24]
    % inputs
        % inputMovie - a string or a cell array of strings pointing to the movies to be analyzed (recommended).
        % numExpectedComponents - number of expected components
    % outputs
        % cnmfAnalysisOutput - structure containing extractedImages and extractedSignals along with input parameters to the algorithm
    % READ BEFORE RUNNING
        % Get CVX from http://cvxr.com/cvx/doc/install.html
        % Run the below commands in Matlab after unzipping
        % cvx_setup
        % cvx_save_prefs (permanently stores settings)

    % changelog
        % 2016.06.20 - updated to keep in line with recent changes to CNMF functions
    % TODO
        %


    % ========================
    % for loading movie
    % turn on parallel
    options.nonCNMF.parallel = 1;

    options.gSig = 3;           % pixel, gaussian width of a gaussian kernel for filtering the data. 0 means no filtering
    options.gSiz = 11;          % pixel, neuron diameter
    options.ssub = 1;           % spatial downsampling factor
    options.tsub = 1;           % temporal downsampling factor
    % get options
    options = getOptions(options,varargin);
    % ========================


    %% clear the workspace and select data
    % clear; clc; close all;

    %% choose data
    inputFilename = inputMovie;
    neuron = Sources2D();
    % nam = get_fullname('\\171.65.115.78\america\data\miniscope\test\2014_10_16_p215_m790_reversalAcq04_small_4\2014_10_16_p215_m790_reversalAcq04_turboreg_crop_dfof_downsample.h5');          % this demo data is very small, here we just use it as an example
    nam = get_fullname(inputFilename);          % this demo data is very small, here we just use it as an example
    nam = neuron.select_data(nam);  %if nam is [], then select data interactively

    %% parameters
    % -------------------------    COMPUTATION    -------------------------  %
    pars_envs = struct('memory_size_to_use', 8, ...   % GB, memory space you allow to use in MATLAB
        'memory_size_per_patch', 0.6, ...   % GB, space for loading data within one patch
        'patch_dims', [64, 64]);  %GB, patch size

    % -------------------------      SPATIAL      -------------------------  %
    gSig = options.gSig;           % pixel, gaussian width of a gaussian kernel for filtering the data. 0 means no filtering
    gSiz = options.gSiz;          % pixel, neuron diameter
    ssub = options.ssub;           % spatial downsampling factor
    with_dendrites = true;   % with dendrites or not
    if with_dendrites
        % determine the search locations by dilating the current neuron shapes
        updateA_search_method = 'dilate';  %#ok<UNRCH>
        updateA_bSiz = 5;
        updateA_dist = neuron.options.dist;
    else
        % determine the search locations by selecting a round area
        updateA_search_method = 'ellipse'; %#ok<UNRCH>
        updateA_dist = 5;
        updateA_bSiz = neuron.options.dist;
    end
    spatial_constraints = struct('connected', true, 'circular', false);  % you can include following constraints: 'circular'
    spatial_algorithm = 'hals_thresh';

    % -------------------------      TEMPORAL     -------------------------  %
    Fs = 10;             % frame rate
    tsub = options.tsub;           % temporal downsampling factor
    deconv_options = struct('type', 'ar1', ... % model of the calcium traces. {'ar1', 'ar2'}
        'method', 'foopsi', ... % method for running deconvolution {'foopsi', 'constrained', 'thresholded'}
        'smin', -5, ...         % minimum spike size. When the value is negative, the actual threshold is abs(smin)*noise level
        'optimize_pars', true, ...  % optimize AR coefficients
        'optimize_b', true, ...% optimize the baseline);
        'max_tau', 100);    % maximum decay time (unit: frame);

    nk = 3;             % detrending the slow fluctuation. usually 1 is fine (no detrending)
    % when changed, try some integers smaller than total_frame/(Fs*30)
    detrend_method = 'spline';  % compute the local minimum as an estimation of trend.

    % -------------------------     BACKGROUND    -------------------------  %
    bg_model = 'ring';  % model of the background {'ring', 'svd'(default), 'nmf'}
    nb = 1;             % number of background sources for each patch (only be used in SVD and NMF model)
    ring_radius = 18;  % when the ring model used, it is the radius of the ring used in the background model.
    %otherwise, it's just the width of the overlapping area
    num_neighbors = []; % number of neighbors for each neuron
    bg_ssub = 2;        % downsample background for a faster speed

    % -------------------------      MERGING      -------------------------  %
    show_merge = false;  % if true, manually verify the merging step
    merge_thr = 0.65;     % thresholds for merging neurons; [spatial overlap ratio, temporal correlation of calcium traces, spike correlation]
    method_dist = 'max';   % method for computing neuron distances {'mean', 'max'}
    dmin = 5;       % minimum distances between two neurons. it is used together with merge_thr
    dmin_only = 2;  % merge neurons if their distances are smaller than dmin_only.
    merge_thr_spatial = [0.8, 0.4, -inf];  % merge components with highly correlated spatial shapes (corr=0.8) and small temporal correlations (corr=0.1)

    % -------------------------  INITIALIZATION   -------------------------  %
    K = [];             % maximum number of neurons per patch. when K=[], take as many as possible.
    min_corr = 0.8;     % minimum local correlation for a seeding pixel
    min_pnr = 8;       % minimum peak-to-noise ratio for a seeding pixel
    min_pixel = gSig^2;      % minimum number of nonzero pixels for each neuron
    bd = 0;             % number of rows/columns to be ignored in the boundary (mainly for motion corrected data)
    frame_range = [];   % when [], uses all frames
    save_initialization = false;    % save the initialization procedure as a video.
    use_parallel = true;    % use parallel computation for parallel computing
    show_init = true;   % show initialization results
    choose_params = false; % manually choose parameters
    center_psf = true;  % set the value as true when the background fluctuation is large (usually 1p data)
    % set the value as false when the background fluctuation is small (2p)

    % -------------------------  Residual   -------------------------  %
    min_corr_res = 0.7;
    min_pnr_res = 6;
    seed_method_res = 'auto';  % method for initializing neurons from the residual
    update_sn = true;

    % ----------------------  WITH MANUAL INTERVENTION  --------------------  %
    with_manual_intervention = false;

    % -------------------------  FINAL RESULTS   -------------------------  %
    save_demixed = true;    % save the demixed file or not
    kt = 3;                 % frame intervals

    % -------------------------    UPDATE ALL    -------------------------  %
    neuron.updateParams('gSig', gSig, ...       % -------- spatial --------
        'gSiz', gSiz, ...
        'ring_radius', ring_radius, ...
        'ssub', ssub, ...
        'search_method', updateA_search_method, ...
        'bSiz', updateA_bSiz, ...
        'dist', updateA_bSiz, ...
        'spatial_constraints', spatial_constraints, ...
        'spatial_algorithm', spatial_algorithm, ...
        'tsub', tsub, ...                       % -------- temporal --------
        'deconv_options', deconv_options, ...
        'nk', nk, ...
        'detrend_method', detrend_method, ...
        'background_model', bg_model, ...       % -------- background --------
        'nb', nb, ...
        'ring_radius', ring_radius, ...
        'num_neighbors', num_neighbors, ...
        'bg_ssub', bg_ssub, ...
        'merge_thr', merge_thr, ...             % -------- merging ---------
        'dmin', dmin, ...
        'method_dist', method_dist, ...
        'min_corr', min_corr, ...               % ----- initialization -----
        'min_pnr', min_pnr, ...
        'min_pixel', min_pixel, ...
        'bd', bd, ...
        'center_psf', center_psf);
    neuron.Fs = Fs;

    %% distribute data and be ready to run source extraction
    neuron.getReady(pars_envs);

    %% initialize neurons from the video data within a selected temporal range
    if choose_params
        % change parameters for optimized initialization
        [gSig, gSiz, ring_radius, min_corr, min_pnr] = neuron.set_parameters();
    end

    [center, Cn, PNR] = neuron.initComponents_parallel(K, frame_range, save_initialization, use_parallel);
    neuron.compactSpatial();
    if show_init
        figure();
        ax_init= axes();
        imagesc(Cn, [0, 1]); colormap gray;
        hold on;
        plot(center(:, 2), center(:, 1), '.r', 'markersize', 10);
    end

    %% estimate the background components
    neuron.update_background_parallel(use_parallel);
    neuron_init = neuron.copy();

    %%  merge neurons and update spatial/temporal components
    neuron.merge_neurons_dist_corr(show_merge);
    neuron.merge_high_corr(show_merge, merge_thr_spatial);

    %% update spatial components

    %% pick neurons from the residual
    [center_res, Cn_res, PNR_res] =neuron.initComponents_residual_parallel([], save_initialization, use_parallel, min_corr_res, min_pnr_res, seed_method_res);
    if show_init
        axes(ax_init);
        plot(center_res(:, 2), center_res(:, 1), '.g', 'markersize', 10);
    end
    neuron_init_res = neuron.copy();

    %% udpate spatial&temporal components, delete false positives and merge neurons
    % update spatial
    if update_sn
        neuron.update_spatial_parallel(use_parallel, true);
        udpate_sn = false;
    else
        neuron.update_spatial_parallel(use_parallel);
    end
    % merge neurons based on correlations
    neuron.merge_high_corr(show_merge, merge_thr_spatial);

    for m=1:2
        % update temporal
        neuron.update_temporal_parallel(use_parallel);

        % delete bad neurons
        neuron.remove_false_positives();

        % merge neurons based on temporal correlation + distances
        neuron.merge_neurons_dist_corr(show_merge);
    end

    %% add a manual intervention and run the whole procedure for a second time
    neuron.options.spatial_algorithm = 'nnls';
    if with_manual_intervention
        show_merge = true;
        neuron.orderROIs('snr');   % order neurons in different ways {'snr', 'decay_time', 'mean', 'circularity'}
        neuron.viewNeurons([], neuron.C_raw);

        % merge closeby neurons
        neuron.merge_close_neighbors(true, dmin_only);

        % delete neurons
        tags = neuron.tag_neurons_parallel();  % find neurons with fewer nonzero pixels than min_pixel and silent calcium transients
        ids = find(tags>0);
        if ~isempty(ids)
            neuron.viewNeurons(ids, neuron.C_raw);
        end
    end
    %% run more iterations
    neuron.update_background_parallel(use_parallel);
    neuron.update_spatial_parallel(use_parallel);
    neuron.update_temporal_parallel(use_parallel);

    K = size(neuron.A,2);
    tags = neuron.tag_neurons_parallel();  % find neurons with fewer nonzero pixels than min_pixel and silent calcium transients
    neuron.remove_false_positives();
    neuron.merge_neurons_dist_corr(show_merge);
    neuron.merge_high_corr(show_merge, merge_thr_spatial);

    if K~=size(neuron.A,2)
        neuron.update_spatial_parallel(use_parallel);
        neuron.update_temporal_parallel(use_parallel);
        neuron.remove_false_positives();
    end

    %%
    % Get the folder path string
    [PATHSTR,NAME,EXT] = fileparts(inputFilename);
    [~,folderName,~] = fileparts(PATHSTR);

    results = neuron.obj2struct();
    cnmfeAnalysisOutput.success = 1;
    cnmfeAnalysisOutput.params = results.options;
    cnmfeAnalysisOutput.movieList = inputFilename;
    cnmfeAnalysisOutput.extractedImages = reshape(full(results.A),[size(results.P.sn) size(results.C,1)]);
    cnmfeAnalysisOutput.extractedSignals = results.C;
    cnmfeAnalysisOutput.extractedSignalsEst = results.C_raw;
    cnmfeAnalysisOutput.extractedPeaks = results.S;
    cnmfeAnalysisOutput.Cn = results.Cn;
    cnmfeAnalysisOutput.P = results.P;
    % save([PATHSTR filesep folderName '_cnmfeAnalysis.mat'],'cnmfeAnalysisOutput');

    % cnmfAnalysisOutput = cnmfeAnalysisOutput;
    % save([PATHSTR filesep folderName '_cnmfAnalysis.mat'],'cnmfAnalysisOutput');


    %% save the workspace for future analysis
    neuron.orderROIs('snr');
    try
        cnmfe_path = neuron.save_workspace();
    catch err
        display(repmat('@',1,7))
        disp(getReport(err,'extended','hyperlinks','on'));
        display(repmat('@',1,7))
    end
    %% show neuron contours
    % Coor = neuron.show_contours(0.6);

    %% create a video for displaying the
    % amp_ac = 140;
    % range_ac = 5+[0, amp_ac];
    % multi_factor = 10;
    % range_Y = 1300+[0, amp_ac*multi_factor];

    % avi_filename = neuron.show_demixed_video(save_demixed, kt, [], amp_ac, range_ac, range_Y, multi_factor);

    %% save neurons shapes
    % neuron.save_neurons();
end