%%

% Input the directories containing img stacks here
sample_dirs = {
  "C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\5 Grade Test Samples\Spec1_100T\100T-image_stack",
  "C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\5 Grade Test Samples\Spec2_80T\80T-image_stack",
  "C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\5 Grade Test Samples\Spec3_60T\60T-image_stack",
  "C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\5 Grade Test Samples\Spec4_40T\40T-image_stack",
  "C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\5 Grade Test Samples\Spec5_20T\20T-image_stack",

};

%%

% This is where the results configuration file will be stored. Follow the
% instructions in the console to configure batch parameters
batch_config = ncorr_batch_setup("C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\5 Grade Test Samples\Spec1_100T\100T-image_stack-ref");
%%

% Point the function to the location of the config file
% input array with paths to sample dirs
% Point function to where to save results mats to

batch_results = ncorr_batch_run(...
"C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\5 Grade Test Samples\results\batch_config.mat", ...
sample_dirs, ...
"C:\Users\patri\UCB-O365\Robert Mac Curdy - MacCurdy Lab\Lab Personnel\Patrick Cavanaugh\Projects\Digital Composite Tensile Testing\5 Grade Test Samples\results" ...
);